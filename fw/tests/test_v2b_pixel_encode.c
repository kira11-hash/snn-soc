/* Standalone host-side sanity test for v2b_encode_pixel_stream_even_rate.
 *
 * Run via:
 *   gcc -std=c11 -O2 -I fw/include fw/tests/test_v2b_pixel_encode.c \
 *       -o /tmp/test_v2b_encode && /tmp/test_v2b_encode
 *
 * Verifies REV 3.3 G2 invariant:
 *   total_spikes(pixel, T) == pixel * T / 256  (integer division)
 *
 * This is a mirror of python_multilayer/tests/test_streamed_rate_parity.py
 * `test_encoder_total_spikes_invariant`.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

/* Don't include full soc_regs.h (pulls in register-memory macros).
 * Inline just the encoder from v2b_primitives.h. */

static inline void v2b_encode_pixel_stream_even_rate(
    const uint8_t *pixels, uint32_t in_dim, uint32_t T,
    uint32_t *stream_bits_out) {
    const uint32_t words_per_row = (in_dim + 31u) / 32u;
    static int32_t acc[1024];
    for (uint32_t i = 0; i < in_dim; i++) acc[i] = 0;
    for (uint32_t t = 0; t < T; t++) {
        uint32_t *row = &stream_bits_out[t * words_per_row];
        for (uint32_t w = 0; w < words_per_row; w++) row[w] = 0u;
        for (uint32_t i = 0; i < in_dim; i++) {
            acc[i] += (int32_t)pixels[i];
            if (acc[i] >= 256) {
                row[i >> 5] |= (1u << (i & 31u));
                acc[i] -= 256;
            }
        }
    }
}

/* Count set bits for a single neuron across T timesteps. */
static uint32_t count_bits_for_neuron(const uint32_t *stream, uint32_t T,
                                      uint32_t in_dim, uint32_t neuron_idx) {
    const uint32_t words_per_row = (in_dim + 31u) / 32u;
    uint32_t count = 0;
    for (uint32_t t = 0; t < T; t++) {
        const uint32_t *row = &stream[t * words_per_row];
        uint32_t w = neuron_idx >> 5;
        uint32_t b = neuron_idx & 31u;
        if (row[w] & (1u << b)) count++;
    }
    return count;
}

#define STREAM_BUF_WORDS (256 * 8)  /* T=256, in_dim≤256 => 8 words/row */
static uint32_t stream_buf[STREAM_BUF_WORDS];

int main(void) {
    const uint8_t test_pixels[] = {0, 1, 64, 127, 128, 191, 255};
    const uint32_t test_Ts[] = {32, 64, 128};
    int errors = 0;
    int tests = 0;

    for (size_t pi = 0; pi < sizeof(test_pixels); pi++) {
        for (size_t ti = 0; ti < sizeof(test_Ts) / sizeof(test_Ts[0]); ti++) {
            uint8_t p = test_pixels[pi];
            uint32_t T = test_Ts[ti];
            uint8_t pixels[1] = {p};
            memset(stream_buf, 0, sizeof(stream_buf));
            v2b_encode_pixel_stream_even_rate(pixels, 1, T, stream_buf);
            uint32_t got = count_bits_for_neuron(stream_buf, T, 1, 0);
            uint32_t expected = ((uint32_t)p * T) / 256u;
            tests++;
            if (got != expected) {
                printf("[FAIL] pixel=%u T=%u got=%u expected=%u\n",
                       p, T, got, expected);
                errors++;
            } else {
                printf("[PASS] pixel=%u T=%u total_spikes=%u\n", p, T, got);
            }
        }
    }

    /* Multi-neuron test: 4 neurons, 4 different pixel values, T=64 */
    uint8_t multi[] = {0, 64, 128, 255};
    memset(stream_buf, 0, sizeof(stream_buf));
    v2b_encode_pixel_stream_even_rate(multi, 4, 64, stream_buf);
    for (uint32_t n = 0; n < 4; n++) {
        uint32_t got = count_bits_for_neuron(stream_buf, 64, 4, n);
        uint32_t exp = ((uint32_t)multi[n] * 64u) / 256u;
        tests++;
        if (got != exp) {
            printf("[FAIL] multi n=%u got=%u exp=%u\n", n, got, exp);
            errors++;
        } else {
            printf("[PASS] multi n=%u total_spikes=%u\n", n, got);
        }
    }

    printf("\n%d tests, %d errors\n", tests, errors);
    if (errors == 0) printf("V2B_PIXEL_ENCODE_TEST_PASS\n");
    else             printf("V2B_PIXEL_ENCODE_TEST_FAIL\n");
    return errors;
}
