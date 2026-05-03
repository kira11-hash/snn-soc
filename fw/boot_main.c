#include "include/soc_regs.h"
#include "include/uart_printf.h"

#include <stdint.h>

#define SPI_CTRL_BOOT_BASE \
    (SPI_CTRL_ENABLE_MASK | (2u << SPI_CTRL_CLKDIV_SHIFT))
#define SPI_CTRL_BOOT_CS_LOW \
    (SPI_CTRL_BOOT_BASE | SPI_CTRL_CS_FORCE_MASK)
#define SPI_POLL_TIMEOUT 0x01000000u

struct boot_header {
    uint32_t magic;
    uint32_t size_bytes;
    uint32_t load_addr;
    uint32_t entry_addr;
};

static void panic(const char *msg);

static void spi_wait_idle(void) {
    uint32_t guard = 0u;
    while ((SPI_STATUS & SPI_STATUS_BUSY_MASK) != 0u) {
        if (++guard >= SPI_POLL_TIMEOUT) {
            panic("spi busy timeout");
        }
    }
}

static void spi_set_cs(int active) {
    SPI_CTRL = active ? SPI_CTRL_BOOT_CS_LOW : SPI_CTRL_BOOT_BASE;
}

static uint8_t spi_xfer(uint8_t tx) {
    uint32_t guard = 0u;
    spi_wait_idle();
    SPI_TXDATA = tx;
    while ((SPI_STATUS & SPI_STATUS_RX_VALID_MASK) == 0u) {
        if (++guard >= SPI_POLL_TIMEOUT) {
            panic("spi rx timeout");
        }
    }
    return (uint8_t)SPI_RXDATA;
}

static void spi_read_bytes(uint32_t addr, uint8_t *dst, uint32_t len) {
    spi_set_cs(1);
    (void)spi_xfer(0x03u);
    (void)spi_xfer((uint8_t)(addr >> 16));
    (void)spi_xfer((uint8_t)(addr >> 8));
    (void)spi_xfer((uint8_t)addr);
    for (uint32_t i = 0; i < len; ++i) {
        dst[i] = spi_xfer(0x00u);
    }
    spi_set_cs(0);
}

static uint32_t spi_read_u32(uint32_t addr) {
    uint8_t bytes[4];
    spi_read_bytes(addr, bytes, 4u);
    return ((uint32_t)bytes[0] << 0)  |
           ((uint32_t)bytes[1] << 8)  |
           ((uint32_t)bytes[2] << 16) |
           ((uint32_t)bytes[3] << 24);
}

static void panic(const char *msg) {
    uart_printf("BL panic: %s\n", msg);
    uart_wait_idle();
    while (1) {
    }
}

int main(void) {
    struct boot_header hdr;
    uint8_t id0, id1, id2;

    uart_init(UART_BAUD_DIV);
    uart_printf("BL start\n");

    spi_set_cs(1);
    (void)spi_xfer(0x9Fu);
    id0 = spi_xfer(0x00u);
    id1 = spi_xfer(0x00u);
    id2 = spi_xfer(0x00u);
    spi_set_cs(0);
    uart_printf("BL rdid=%x%x%x\n", (uint32_t)id0, (uint32_t)id1, (uint32_t)id2);

    hdr.magic      = spi_read_u32(0u);
    hdr.size_bytes = spi_read_u32(4u);
    hdr.load_addr  = spi_read_u32(8u);
    hdr.entry_addr = spi_read_u32(12u);

    if (hdr.magic != BOOT_IMAGE_MAGIC) {
        panic("bad magic");
    }
    if ((hdr.size_bytes == 0u) || (hdr.size_bytes > APP_LOAD_MAX_BYTES)) {
        panic("bad size");
    }
    if (hdr.load_addr != APP_LOAD_ADDR || hdr.entry_addr != APP_LOAD_ADDR) {
        panic("bad addr");
    }

    uart_printf("BL size=%u\n", hdr.size_bytes);
    spi_read_bytes(16u, (uint8_t *)hdr.load_addr, hdr.size_bytes);
    BOOT_MARK_ADDR = BOOT_MARK_VALUE;
    uart_printf("BL jump\n");

    __asm__ volatile ("fence.i" ::: "memory");
    ((void (*)(void))hdr.entry_addr)();

    panic("returned");
    return 0;
}
