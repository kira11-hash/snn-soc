# Silicon Bring-up Guide — 事无巨细操作手册

> **Scope**：流片回来之后，**任何人**（哪怕不熟悉这个项目）都能按这份文档
> 一步一步把芯片点亮、自检、集成、全链路验证。
>
> **配套计划文档**：`doc/silicon_bringup_plan.md`（strategy 视角，按"为什么"组织）
> 本文档按"怎么做"组织，可以作为实操 SOP 使用。

---

## 0. 名词快速对照

| 术语 | 物理实体 / 含义 |
|---|---|
| **数字 die** | 本项目的数字芯片（E203 + SNN SoC），pad 数 48 |
| **模拟 die** | 分开流片的 CIM 模拟芯片（RRAM 阵列 + ADC），pad 数 48 |
| **Mask ROM** | 数字 die 上一小块（4 KB）只读存储区，内容在工厂流片时用掩膜层固化。地址 0x0000_0000~0x0000_0FFF |
| **INSTR_SRAM** | 数字 die 上 16 KB 可读写指令存储。开启 Mask ROM 时位于 0x0000_1000~0x0000_4FFF |
| **Bootloader** | 烧在 Mask ROM 里的一小段代码（~2 KB），负责从 SPI flash 读应用固件到 INSTR_SRAM 并跳转 |
| **SPI flash** | 焊在 PCB 上的外置非易失存储（如 W25Q128，几块钱一颗）。内容可用 USB programmer 任意重烧 |
| **Application firmware** | 实际跑的固件（silicon_bringup / e203_fpga_smoke 等），放在 SPI flash 里，boot 时复制到 INSTR_SRAM |
| **JTAG rescue** | 备用救援通道：用 PC 通过 JTAG 把固件直接塞进 INSTR_SRAM，绕过 SPI flash 启动 |
| **J83** | ZCU102 板上的 CP2108 USB-UART 口（bring-up 专用）。在你的测试板上对应相应 USB-UART 口 |
| **J18** | ZCU102 板上的 USB-JTAG 口（丝印 "USB JTAG"）。在测试板上对应 JTAG 调试口 |

---

## 1. 硬件准备清单（bring-up 前必须就位）

### 1.1 芯片

- [ ] 数字 die（按当前 `doc/15_asic_pad_map.md` 的 55-pad 冻结口径；若带 mask ROM，则需已烧录 bootloader）
- [ ] 模拟 die（可以后来再装，Day 1/2 不需要）

### 1.2 PCB 板

- [ ] 数字 die 焊上板
- [ ] 模拟 die 位置（Day 3 前可以空焊）
- [ ] **SPI flash 芯片**：焊上板，SOIC-8 封装，W25Q128 或等效（16 MB，市场主流）。必要信号：
      `CLK` ↔ 数字 die 的 `spi_sck_pad`
      `DI`  ↔ 数字 die 的 `spi_mosi_pad`
      `DO`  ↔ 数字 die 的 `spi_miso_pad`
      `CS`  ↔ 数字 die 的 `spi_cs_n_pad`
      `WP`、`HOLD` 管脚接 3.3V（禁用硬件写保护和 hold 功能）
      `VCC`、`GND` 按数字 die 供电
- [ ] **外部晶振** 或 clock source（50 MHz 或 onboard MMCM 出来的 50 MHz 都行）
- [ ] **Reset 按钮**：机械按钮接到数字 die 的 `rst_n_pad`（高→低→高 一次触发复位）
- [ ] **UART 引出**：数字 die 的 `uart_tx_pad` / `uart_rx_pad` 接 board 上的 level shifter → CP2108 或 USB-UART 模块
- [ ] **JTAG 引出**：数字 die 的 `jtag_tck/tms/tdi/tdo_pad` 接到板上 20-pin ARM JTAG 或 14-pin TI JTAG 座
- [ ] **LED 活体指示**（强烈建议）：把 `led[0..3]` 引到 4 颗 LED，用于目视判断时钟、复位、状态

### 1.3 PC 侧工具

- [ ] **USB-JTAG 适配器**：Xilinx platform cable / FTDI FT2232H / Olimex ARM-USB-TINY 任一
- [ ] **USB-UART 适配器**（如果板上没集成 CP2108）：CH340 / CP2102，3.3V 电平
- [ ] **CH341A USB programmer + SOIC-8 测试夹**（SPI flash 烧录用，合计 ¥80~¥100）
- [ ] Vivado / Vitis（xsct 命令）
- [ ] Python 3 + `pyserial`（`pip install pyserial`）
- [ ] PuTTY 或等效串口工具

### 1.4 Tape-out 物理签核补充项（必须和后端/器件老师对齐）

- [ ] **Pad library 电压域**：确认 UART / SPI / JTAG / reset / LED / 模拟互联 pad 所选 IO cell 电压与板级外设兼容。
      如果数字 die pad ring 是 1.8V，而 SPI flash / USB-UART / JTAG dongle 是 3.3V，必须明确：
      - 板上做电平转换，或
      - 改用 1.8V 兼容器件，或
      - tape-out 选 3.3V tolerant IO option
- [ ] **ESD 策略**：`doc/15_asic_pad_map.md` 里保留的 ESD / reserved pad 是否已在 pad ring 方案里真正落地；外部 SPI/JTAG/UART 口不能只靠板级 ESD 代替芯片级 ESD。
- [ ] **Drive strength / slew**：SPI `sck/cs/mosi`、UART TX、JTAG TCK/TMS/TDI/TDO、以及数字→模拟 die 的 `wl_* / cim_start / bl_sel` 是否都选了合适的 drive strength；过弱会边沿太慢，过强会带来串扰和 EMI。
- [ ] **上电默认态**：reset、CS、JTAG TMS/TCK、UART TX 空闲态是否有 pad 侧 pull-up / pull-down 方案，避免上电毛刺误触发 SPI 写保护、JTAG 进入异常 TAP 状态、或 bootloader 读到垃圾。
- [ ] **SPI flash 供电兼容性**：flash 的 `VCC` / `WP` / `HOLD` 接法和数字 die VCCIO 是否完全一致，特别是如果板子上 flash 常供电、数字 die 分域上电，必须确认不会通过 IO 反向灌电。
- [ ] **ROM mask 内容 handoff**：后端 / Foundry 拿到的 ROM image 必须来自 `fw/boot_rom/out/boot_rom.bin`，并记录 SHA；不能手工拷贝旧版本 hex。
- [ ] **SRAM macro wrapper 对齐**：`sram_simple(.sv/.dp.sv)` 只是行为模型。后端接 foundry SRAM macro 前，必须确认 byte-write、读时序、读写冲突语义和 macro wrapper 一致；若不一致，必须在流片前补 wrapper，而不是在版图后临时改。

---

## 2. Day 1 —— 光数字 die 的自检（JTAG rescue 路径）

**目标**：证明数字 die 本身所有数字子系统都活。
**前提**：SPI flash 可以没烧内容。模拟 die 可以不焊。

### 2.1 开机顺序

```
1. 板子通电 → 按一次 reset 按钮 → 松开
2. CPU 从 0x0 取指 → 读到 boot ROM 里的 bootloader（内容在流片时已固化）
3. Bootloader 尝试从 SPI flash 读 magic word
4. SPI flash 里什么都没有 → magic word 不对 → bootloader 进入"JTAG rescue 等待"状态
   这个状态下 bootloader 在 UART 打印 "BL: waiting for JTAG" 然后 WFI
5. LED 观察：应该看到
     LED[0] 闪烁（heartbeat，0.67 Hz 慢闪 = 时钟在跑）
     LED[1] 常亮（mmcm_locked 或 ROM boot 活体标志，视 chip_top 实现）
     LED[2] 常亮（reset 已释放）
     LED[3] 灭
6. UART：PuTTY 开对应 COM 口，115200 8N1 无流控，应该看到：
     BL start
     BL rdid=...
     BL: SPI magic mismatch, entering JTAG rescue wait
     BL: waiting for JTAG
```

### 2.2 用 JTAG 塞固件

```
1. PC 连上 JTAG 适配器（pyftdi 兼容的 FT2232H / FT4232H cable）→ 板上 JTAG 口
2. 先把 silicon_bringup 固件编译成 $readmemh 格式（jtag_rescue 只吃 .hex）：
   wsl bash fw/silicon_bringup/build_silicon_bringup.sh
   → 产出 fw/silicon_bringup/out/silicon_bringup.hex（4096 words, NOP-padded）
3. 在仓库根目录跑：
   python scripts/jtag_rescue.py \
       --backend pyftdi \
       --url "ftdi:///1" \
       --frequency 1000000 \
       rescue-load \
           fw/silicon_bringup/out/silicon_bringup.hex \
           --load-addr 0x1000
   说明：
     --load-addr 0x1000 是 tape-out 路径（chip_top.ENABLE_BOOT_ROM=1）下 INSTR_SRAM
     的真实基址；省略该参数则默认 0x0（V1 legacy 路径，ROM 未启用时使用）。
4. jtag_rescue.py 做 3 件事：
   a. 发 CPUCTL IR 把 CPU 锁在 reset (hold=1)
   b. 通过 MEMACC IR 把 silicon_bringup.hex 逐字写到指定 load-addr
   c. 发 CPUCTL IR 释放 CPU (hold=0)，CPU 从 reset vector (mask ROM) 重启，
      boot_rom_main 走 SPI flash 分支 (magic 错 → rescue wait) 或直接 fall
      through 到 INSTR_SRAM 跑刚写进去的代码
5. UART 应该打印：
     SILICON_BRINGUP_START v1 build=...
     [STAGE_A] inference with test_mode=1, pos=100, neg=0
     [STAGE_A] neuron[0] hw=80 sw=80 OK
     [STAGE_A] neuron[1] hw=80 sw=80 OK
     ... (到 neuron[9])
     [STAGE_A] total_spikes=800 mismatch=0
     [STAGE_B] programming FSM with bypass_handshake=1
     [STAGE_B] erase  PROG_STATUS=0x82
     [STAGE_B] write  PROG_STATUS=0x82
     SILICON_BRINGUP_DIGITAL_PASS
6. 看到 `SILICON_BRINGUP_DIGITAL_PASS` → Day 1 成功
```

### 2.3 Day 1 失败诊断表

| UART 看到的最后一行 | 诊断 | 下一步 |
|---|---|---|
| 啥都没打印 | 串口线、波特率、pad 输出、ROM boot 本身可能坏 | 先测 TX 管脚有没有 8N1 波形；测 ROM boot 的 `BL start` 是否出现 |
| `BL start` 之后就停住 | bootloader 在 ROM 里跑，但 SPI 或 JTAG 分支挂了 | 检查 SPI 管脚是否正确焊接、CS 是否拉起 |
| `BL: SPI magic mismatch, entering JTAG rescue wait` 之后 jtag_rescue 塞完不跑 | JTAG chain 或 CPU reset hold 有问题 | 用 openocd 跑 IR/DR 扫描，比对 IDCODE |
| `SILICON_BRINGUP_DIGITAL_FAIL_DMA` | DMA 外设坏 | 查 DMA fabric 管脚，在 TB 上复现 |
| `SILICON_BRINGUP_DIGITAL_FAIL_CIM_TIMEOUT` | CIM 控制 FSM 死锁 | 检查 REG_CIM_TEST 是否确实写入（可以通过 JTAG 读回寄存器） |
| `SILICON_BRINGUP_DIGITAL_FAIL_INFER` | HW 与软件 LIF 不符 | ADC Scheme B 或 LIF 通路有 bug，抓 debug 计数器 |
| `SILICON_BRINGUP_DIGITAL_FAIL_PROG_*` | 编程 FSM 有 bug | BYPASS_HANDSHAKE 位被忽略，或 arbiter 没切到编程侧 |

**Day 1 过 = 数字 die 数字部分全功能可用**。可以立即进入 Day 2。

---

## 3. SPI flash 内容怎么写入（两种方式详解）

在讲 Day 2 之前，必须先解决"怎么把固件写进 SPI flash"这个工程问题。两种方式：

### 3.1 方式 B（推荐，bring-up 阶段主力）：CH341A + SOIC-8 夹子在路烧录

**器材清单**：
- CH341A USB programmer（¥30）
- SOIC-8 pogo-pin 测试夹（¥50）
- Windows 下烧录软件：**neoprogrammer** 或 **CH341A Programmer v1.4**

**操作步骤**：

```
1. 准备 .bin 文件（带 boot header）:
   - header = 16 字节
     [0..3]   magic    = 0x544F4F42 (`'BOOT'`, little-endian)
     [4..7]   size     = uint32 LE (固件字节数)
     [8..11]  load_addr = 0x0000_1000
     [12..15] entry_addr= 0x0000_1000
   - 接 silicon_bringup.bin 或 e203_fpga_smoke.bin 原始字节
   - 命令（Linux / WSL）:
     python scripts/make_boot_image.py \
         --firmware fw/silicon_bringup/out/silicon_bringup.bin \
         --load-addr 0x1000 \
         --entry-addr 0x1000 \
         --out        flash_image.bin

2. 物理连接:
   - 把 SOIC-8 夹子卡住板上 SPI flash 芯片 (注意 pin 1 方向对齐)
   - CH341A 的 8 脚排针插入夹子: 确认 VCC / GND / CLK / DI / DO / CS 对应正确
   - CH341A 通过 USB 连接 PC
   - 板子 reset 按钮按住不放，或者板子断电 (防止数字 die 的 SPI master 和 CH341A 争总线)

3. 烧录:
   - 打开 neoprogrammer
   - 选择芯片型号: W25Q128 (自动检测也可以)
   - 点 "Read IC" 先读一次现有内容 (确认连接正常) -> 读出的 bytes 应该非空 if previously flashed, or 全 0xFF if blank
   - 点 "Open" 选 flash_image.bin
   - 点 "Auto" (= Erase + Write + Verify) -> 约 30-60 秒完成
   - 看到 "Verify OK" = 烧录成功

4. 恢复板子:
   - 拔掉 CH341A 夹子
   - 释放 reset 按钮 (或者重新给板子上电)

5. 验证: 进入 Day 2 流程
```

**方式 B 的注意事项**：
- **VCC 冲突**：CH341A 会通过夹子给 flash 3.3V 供电。如果板子同时供电，两个 VCC 会冲突。**解决**：烧录时断掉板子主电源；或者拆掉夹子上的 VCC pin（一些夹子带跳线）
- **CS 争用**：数字 die 的 SPI master CS 如果处于 active 状态，会和 CH341A 争夺 flash。**解决**：reset 按钮按住；确保 bootloader 没进入 SPI 访问循环
- **速度**：烧 16 MB flash 全片 ~2-3 分钟；仅烧 4 KB bring-up 固件 ~10 秒

### 3.2 方式 C（进阶，bring-up 稳定后使用）：数字 die 自己烧 flash

**前提**：Day 1 已经证明数字 die + SPI master 工作正常。

**需要额外写的固件**（**本仓库目前仍没有**，TODO list）：

`fw/spi_writer/spi_writer.c` — 一段常驻 SRAM 的固件，接收来自 UART 或 JTAG 的新 flash 内容，调用自己的 SPI master 写入：

```c
// 伪代码，完整实现需 ~200 行
while (1) {
    uart_puts("SPI_WRITER ready. send 4B: length, then payload\n");
    uint32_t len = uart_read_u32();
    uint32_t target_addr = uart_read_u32();
    uint32_t page_cnt = (len + 255) / 256;

    // 1. Erase (sector erase 0x20, 4 KB per op)
    for (uint32_t s = target_addr; s < target_addr + len; s += 0x1000) {
        spi_wren();
        spi_erase_sector(s);
        spi_wait_wip_clear();
    }

    // 2. Page program (0x02, 256 B per op)
    for (uint32_t p = 0; p < page_cnt; p++) {
        uint8_t buf[256];
        uart_read_bytes(buf, 256);
        spi_wren();
        spi_page_program(target_addr + p*256, buf, 256);
        spi_wait_wip_clear();
    }

    // 3. Verify (0x03 read-back + memcmp)
    ...
    uart_puts("SPI_WRITE_OK\n");
}
```

**操作步骤（假设 spi_writer.bin 已存在）**：

```
1. JTAG rescue 先把 spi_writer.bin 塞进 INSTR_SRAM @ 0x1000 并跳转:
   python scripts/jtag_rescue.py --firmware spi_writer.bin \
                                 --load-addr 0x1000 --entry-addr 0x1000

2. UART 应该看到:
     SPI_WRITER ready. send 4B: length, then payload

3. 从 PC 用 python script 把新 flash 内容通过 UART 送进去:
   python scripts/uart_upload_flash.py \
         --port COM3 --firmware flash_image.bin --target-addr 0x0
   (uart_upload_flash.py 需要新写 —— TODO)

4. UART 看到 SPI_WRITE_OK -> flash 已更新

5. 断电、去掉 JTAG、重新上电 -> 芯片自己走 Day 2 流程
```

**方式 C 的好处**：不用拔芯片、不用外置烧录器、一条 USB 搞定
**方式 C 的坏处**：先要 Day 1 完全通；spi_writer.c 自己可能有 bug，调试会复杂

### 3.3 缺的工具清单（都是轻量级开发项）

| 工具 | 用途 | 工作量 | 优先级 |
|---|---|---|---|
| `scripts/make_boot_image.py` | 生成带 16 B header 的 .bin | 已完成 | 高（Day 2 已可执行）|
| `fw/spi_writer/` | 在路烧录固件 | ~200 行 C，半天 | 中（方式 C 需要） |
| `scripts/uart_upload_flash.py` | PC 侧配套上位机 | ~100 行 Python，1 小时 | 中（方式 C 需要） |
| `scripts/make_golden_log.py` | 保存期望 UART 输出用于 CI 对比 | ~50 行 Python，半小时 | 低 |

---

## 4. Day 2 —— 完整 SPI boot 启动链

**目标**：证明 mask ROM + SPI flash + bootloader + 应用固件整个启动链工作。
**前提**：Day 1 已过，SPI flash 按方式 B 或 C 烧好了带 header 的 `silicon_bringup.bin`。

### 4.1 开机顺序

```
1. 板子断电 → 通电 → 按一次 reset 按钮
2. CPU PC=0x0000_0000 → 从 mask ROM 取指 → 开始执行 bootloader:
   a. uart_init, 打 "BL start"
   b. spi_init, 读 flash [0..15] 作为 header
   c. 验证 magic = 0x544F4F42 ('BOOT') -> 读 size / load_addr / entry_addr
   d. 通过 SPI 直接把 flash[16..16+size] 读到 INSTR_SRAM (0x0000_1000..)
   e. 打 "BL size=<size>"，然后 "BL jump to 0x1000"
   f. jal 0x0000_1000 (或者 jr ra with ra=entry_addr)
3. CPU 到 0x0000_1000 → INSTR_SRAM 里是 silicon_bringup 代码
4. silicon_bringup 自检流程启动 -> 跟 Day 1 JTAG 塞固件之后看到的一样
5. UART 最终输出:
     BL start
     BL rdid=XX YY ZZ         (flash ID, 调试用)
     BL size=<N>
     BL jump to 0x1000
     SILICON_BRINGUP_START v1 build=...
     ... (Stage A / Stage B)
     SILICON_BRINGUP_DIGITAL_PASS
```

### 4.2 Day 2 失败诊断表

| 症状 | 诊断 | 对策 |
|---|---|---|
| `BL start` 之后停 | SPI flash 没读出来 | 用示波器看 SCK/MOSI/MISO 有无波形；用 CH341A 再读一次 flash 内容 |
| `BL rdid=00 00 00` | SPI flash MISO 没信号 | 焊接问题 或 flash 没供电 |
| `BL rdid=EF 40 17` 正常但紧跟 `BL: SPI magic mismatch...` | flash 里内容没带 header 或 header 被擦坏 | 回到方式 B/C 重新烧 |
| `BL size=<size>` 但之后没 `BL jump` | SPI 读 payload / SRAM 落点有问题 | 检查 `load_addr` / `entry_addr` 是否都是 0x1000，确认 flash image header 正确 |
| `BL jump to 0x1000` 之后没有 silicon_bringup 输出 | 固件本身或 INSTR_SRAM 内容损坏 | 重烧 flash |
| 看到 `SILICON_BRINGUP_DIGITAL_FAIL_*` | 同 Day 1 对应错误 | 查 Day 1 诊断表 |

**Day 2 过 = 数字 die 可以独立上电启动，不再需要 JTAG 即可跑任何应用固件**。

---

## 5. Day 3 —— 加装模拟 die，跑真推理

**目标**：证明数字 + 模拟 + 数模接口三者都工作，芯片达到 paper 可写的水平。
**前提**：Day 2 已过。

### 5.1 准备

- [ ] 模拟 die 焊上板（或通过小板卡对接）
- [ ] PCB 上数字 die ↔ 模拟 die 的 pad 对接核对：
      `wl_data[7:0]` / `wl_group_sel[2:0]` / `wl_latch` 数字 → 模拟
      `cim_start` / `bl_sel[4:0]` 数字 → 模拟
      `cim_done` / `bl_data[7:0]` 模拟 → 数字
- [ ] 换一份 flash 内容：`e203_fpga_smoke.bin` 替换 `silicon_bringup.bin`（两个固件的区别：silicon_bringup 写 `REG_CIM_TEST.test_mode=1`，smoke 不写这位 → smoke 走真模拟宏）

### 5.2 烧 flash + 开机

```
1. 用方式 B (CH341A) 或方式 C (在路 UART 烧) 把 e203_fpga_smoke.bin 写进 flash
2. 断电 reset 重上电
3. UART 应该看到:
     BL start
     BL rdid=...
     BL size=2268
     BL jump to 0x1000
     UART_OK
     FPGA_E203_BOOT_UART_PASS                  ← Gate 1
     [PROG] full-array erase DONE
     [PROG] write rows=0..9 cols=0..9 PASS
     FPGA_E203_PROGRAM_ERASE_WRITE_PASS         ← Gate 2
     [INFER] neuron[0] hw=80 sw=80 OK
     ...
     [INFER] total_spikes=800 mismatch=0
     FPGA_E203_PROGRAMMED_INFERENCE_PASS        ← Gate 3
```

### 5.3 Day 3 失败诊断

核心判断逻辑：

- **如果 Stage 1 (`FPGA_E203_BOOT_UART_PASS`) 通不过** → 和 Day 2 一样，跟模拟 die 无关，查 bootloader + 基础 UART
- **如果 Stage 1 过、Stage 2 卡在 programming** → **模拟 die 的编程电压 / 脉冲生成 / RRAM cell 写入机制有 bug**，找器件老师查 SPICE 模型 vs 实测
- **如果 Stage 2 过、Stage 3 `mismatch != 0`** → **模拟侧推理通路** 某个位置有偏差（ADC 线性度、Scheme B 差分增益、DAC 电压精度都有可能），需要分通道对比实测 ADC output 和软件模型

### 5.4 Day 3 过 = 芯片可用，允许写论文

此时可以写：

> "The V1 SNN SoC silicon was functionally validated with the E203
>  RISC-V soft-core executing the digital erase/write/verify
>  programming protocol against the analog CIM die, followed by
>  SNN inference with bit-exact output spike counts (800 spikes,
>  zero mismatch against the software LIF reference)."

---

## 6. 应急：JTAG rescue 永远可用

无论 Day 几，只要 mask ROM、JTAG TAP、`jtag_mem_loader` 这三样活着，就可以绕过 SPI flash + bootloader 流程，用 PC 直接塞任何固件跑。命令（已在 2.2 给过）：

```bash
python scripts/jtag_rescue.py \
    --firmware <任何 .bin> \
    --load-addr 0x0000_1000 \
    --entry-addr 0x0000_1000
```

这是 silicon bring-up 的最终保险。

---

## 6.5 Mask ROM handoff（给后端 / Foundry）

当前仓库里的 ROM 源内容和交付链如下：

1. 源码：`fw/boot_rom/boot_rom_main.c`
2. 构建：`bash fw/boot_rom/build_boot_rom.sh`
3. 产物：
   - `fw/boot_rom/out/boot_rom.bin`
   - `fw/boot_rom/out/boot_rom.hex`
4. SoC 连接：
   - `chip_top` 里 `ENABLE_BOOT_ROM=1`
   - `BOOT_ROM_INIT_FILE` 仅用于仿真 / FPGA
   - 正式流片时由 foundry ROM compiler / memory compiler 生成 mask ROM macro，内容来源必须与 `boot_rom.bin` / `boot_rom.hex` 一致

**handoff 规则**：

- RTL 仿真 / FPGA 用 `boot_rom.hex`
- ROM compiler / foundry 交付用 `boot_rom.bin` 或 compiler 需要的等价格式
- backend signoff 文档必须记录：
  - git commit hash
  - `boot_rom.bin` SHA256
  - `boot_rom.hex` SHA256
  - 目标地址窗口：`0x0000_0000..0x0000_0FFF`

如果 ROM 内容改了，必须重新跑：

```bash
bash fw/boot_rom/build_boot_rom.sh
bash sim/run_chip_top_rom_smoke.sh
```

这两步都绿了，才能把新 ROM 内容交给后端 / Foundry。

---

## 7. 验收 checklist

| 阶段 | 判据 | 过没过 |
|---|---|---|
| Day 1 | UART 看到 `SILICON_BRINGUP_DIGITAL_PASS` | ☐ |
| Day 2 | 重上电即看到 `BL start` → `BL jump to 0x1000` → `SILICON_BRINGUP_DIGITAL_PASS`，不需要 JTAG 介入 | ☐ |
| Day 3 | 重上电后看到 `FPGA_E203_BOOT_UART_PASS` + `FPGA_E203_PROGRAM_ERASE_WRITE_PASS` + `FPGA_E203_PROGRAMMED_INFERENCE_PASS`，`total_spikes=800 mismatch=0` | ☐ |
| 证据归档 | 所有 UART 日志保存到 `doc/silicon_bringup/board_bringup_log_day<N>.txt`，带 bitstream SHA / firmware SHA / git commit hash | ☐ |
| 照片证据 | 整板照（带 SPI flash 焊点清晰）+ UART 终端截图（含三阶段 PASS）+ Vivado 时序报告 + 设备管理器截图 | ☐ |

---

## 8. 补遗：仓库里还需要补齐的东西（按优先级排）

| # | 缺失 | 阻塞哪一步 |
|---|---|---|
| 1 | `fw/boot_rom/boot_rom_main.c` | 已完成：ROM 里的 bootloader，适配 ROM@0x0 / app@0x1000 |
| 2 | `fw/link_app.ld` | 已完成：应用固件链接到 `0x0000_1000` |
| 3 | `scripts/make_boot_image.py` | 已完成：生成带 16 B header 的 boot image |
| 4 | `fw/spi_writer/` — 方式 C 所需自烧固件 | 仍缺失；方式 C，不阻塞 Day 2 |
| 5 | `scripts/uart_upload_flash.py` — 方式 C 配套 PC 侧工具 | 仍缺失；方式 C，不阻塞 Day 2 |
| 6 | `tb/chip_top_rom_smoke_tb.sv` + `sim/run_chip_top_rom_smoke.sh` | 已完成：`ENABLE_BOOT_ROM=1` 综合级 ROM boot smoke |

当前阻塞 tape-out 的 Day 2 基础链已具备：ROM bootloader、0x1000 app linker、boot image 打包脚本、chip_top ROM smoke 都已落地。方式 C 相关工具仍可在流片等待期补齐。

---

*文档版本：v1，日期：2026-04-23*
*作者：Claude (Opus 4.7)，维护人：Qingan Chen*
