#include "../include/soc_regs.h"
#include "../include/uart_printf.h"

#include <stdint.h>

#define ROM_APP_BASE       0x00001000u
#define ROM_APP_END        0x00005000u
#define ROM_APP_MAX_BYTES  (ROM_APP_END - ROM_APP_BASE)

#define SPI_CTRL_BOOT_BASE \
    (SPI_CTRL_ENABLE_MASK | (2u << SPI_CTRL_CLKDIV_SHIFT))
#define SPI_CTRL_BOOT_CS_LOW \
    (SPI_CTRL_BOOT_BASE | SPI_CTRL_CS_FORCE_MASK)

struct boot_header {
    uint32_t magic;
    uint32_t size_bytes;
    uint32_t load_addr;
    uint32_t entry_addr;
};

static void spi_wait_idle(void) {
    while ((SPI_STATUS & SPI_STATUS_BUSY_MASK) != 0u) {
    }
}

static void spi_set_cs(uint32_t active) {
    SPI_CTRL = active ? SPI_CTRL_BOOT_CS_LOW : SPI_CTRL_BOOT_BASE;
}

static uint8_t spi_xfer(uint8_t tx) {
    spi_wait_idle();
    SPI_TXDATA = tx;
    while ((SPI_STATUS & SPI_STATUS_RX_VALID_MASK) == 0u) {
    }
    return (uint8_t)SPI_RXDATA;
}

static void spi_read_bytes(uint32_t addr, uint8_t *dst, uint32_t len) {
    spi_set_cs(1u);
    (void)spi_xfer(0x03u);
    (void)spi_xfer((uint8_t)(addr >> 16));
    (void)spi_xfer((uint8_t)(addr >> 8));
    (void)spi_xfer((uint8_t)addr);
    for (uint32_t i = 0u; i < len; ++i) {
        dst[i] = spi_xfer(0x00u);
    }
    spi_set_cs(0u);
}

static uint32_t spi_read_u32(uint32_t addr) {
    uint8_t b[4];
    spi_read_bytes(addr, b, 4u);
    return ((uint32_t)b[0] << 0)  |
           ((uint32_t)b[1] << 8)  |
           ((uint32_t)b[2] << 16) |
           ((uint32_t)b[3] << 24);
}

static void wait_for_rescue(const char *reason) {
    uart_printf("BL: %s, entering JTAG rescue wait\n", reason);
    uart_puts("BL: waiting for JTAG\n");
    uart_wait_idle();
    for (;;) {
        __asm__ volatile ("wfi");
    }
}

static int app_range_ok(uint32_t load_addr, uint32_t size_bytes,
                        uint32_t entry_addr) {
    if ((load_addr & 3u) != 0u || (entry_addr & 3u) != 0u) {
        return 0;
    }
    if (size_bytes == 0u || size_bytes > ROM_APP_MAX_BYTES) {
        return 0;
    }
    if (load_addr < ROM_APP_BASE || load_addr > ROM_APP_END) {
        return 0;
    }
    if (size_bytes > (ROM_APP_END - load_addr)) {
        return 0;
    }
    if (entry_addr < load_addr || entry_addr >= (load_addr + size_bytes)) {
        return 0;
    }
    return 1;
}

int main(void) {
    struct boot_header hdr;
    uint8_t id0, id1, id2;

    uart_init(UART_BAUD_DIV);
    uart_puts("BL start\n");

    spi_set_cs(1u);
    (void)spi_xfer(0x9Fu);
    id0 = spi_xfer(0x00u);
    id1 = spi_xfer(0x00u);
    id2 = spi_xfer(0x00u);
    spi_set_cs(0u);
    uart_printf("BL rdid=%x%x%x\n", (uint32_t)id0, (uint32_t)id1, (uint32_t)id2);

    hdr.magic      = spi_read_u32(0u);
    hdr.size_bytes = spi_read_u32(4u);
    hdr.load_addr  = spi_read_u32(8u);
    hdr.entry_addr = spi_read_u32(12u);

    if (hdr.magic != BOOT_IMAGE_MAGIC) {
        wait_for_rescue("SPI magic mismatch");
    }
    if (!app_range_ok(hdr.load_addr, hdr.size_bytes, hdr.entry_addr)) {
        wait_for_rescue("bad app header");
    }

    uart_printf("BL size=%u\n", hdr.size_bytes);
    spi_read_bytes(16u, (uint8_t *)(uintptr_t)hdr.load_addr, hdr.size_bytes);
    BOOT_MARK_ADDR = BOOT_MARK_VALUE;
    uart_printf("BL jump to 0x%x\n", hdr.entry_addr);
    uart_wait_idle();

    __asm__ volatile ("fence.i" ::: "memory");
    ((void (*)(void))(uintptr_t)hdr.entry_addr)();

    wait_for_rescue("app returned");
    return 0;
}
