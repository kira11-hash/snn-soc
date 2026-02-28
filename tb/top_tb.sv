// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: tb/top_tb.sv
// Purpose: Top-level simulation testbench that drives register programming and validates the MVP datapath integration.
// Role in system: Provides smoke-test style functional coverage before firmware/CPU integration.
// Behavior summary: Generates clock/reset, drives the simple bus via helper tasks, loads sample data, starts compute, checks outputs.
// Wave dump note: Simulator-specific dump calls may need guards when using Verilator vs VCS/Verdi.
// Debug strategy: Assertions and printed checkpoints target stage handshakes and end-to-end completion, not only final scores.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: top_tb.sv
// 描述: SNN SoC 顶层 Testbench。
//       完整流程：配置寄存器 -> 写入 data_sram -> DMA -> 推理 -> 读取输出。
//       生成 FSDB 波形供 Verdi 使用。
//       适配 V1 参数：NUM_INPUTS=64, ADC_BITS=8, T=10, Scheme B（定版）。
//======================================================================
//
// -----------------------------------------------------------------------
// 测试流程总览（5 个阶段）：
//
//   Phase 1: 寄存器配置
//     - 写 REG_THRESHOLD（0x4000_0000）：设置 LIF 神经元阈值
//     - 写 REG_TIMESTEPS（0x4000_0004）：设置时步数/帧数（=10，定版 TIMESTEPS_DEFAULT）
//     - 读 REG_THRESHOLD_RATIO（0x4000_0024）：验证默认值（期望 4，ratio_code=4/255≈0.0157）
//
//   Phase 2: 写入 data_sram（bit-plane 编码）
//     - 每个像素值（8-bit）展开为 8 个 bit-plane（MSB 优先）
//     - 每个 bit-plane = NUM_INPUTS=64 bit = 2 个 32-bit word
//     - 写入地址：data_sram 起始地址 0x0001_0000
//     - 总共写入：frames × PIXEL_BITS × 2 = 10 × 8 × 2 = 160 words
//     - 这是 DMA_LEN_WORDS=160（偶数，满足 DMA 要求）
//
//   Phase 3: DMA 传输
//     - 写 DMA_SRC_ADDR（0x4000_0100）：= 0x0001_0000（data_sram 起始）
//     - 写 DMA_LEN_WORDS（0x4000_0104）：= 160（T=10 × 8 个 bit-plane × 每 plane 2 words）
//     - 写 DMA_CTRL.START（0x4000_0108）：W1P 触发
//     - 轮询 DMA_CTRL.DONE（bit[1]）：等待传输完成
//
//   Phase 4: CIM 推理
//     - 写 CIM_CTRL.START（0x4000_0014）：W1P 触发 SNN 推理
//     - 轮询 CIM_CTRL.DONE（bit[7]）：等待 SNN 完成
//     - 读 ADC_SAT_COUNT（0x4000_0028）：诊断 ADC 饱和情况
//     - 读 DBG_CNT_0/1（0x4000_0030/0034）：读取 debug 计数器
//     - 读 CIM_TEST（0x4000_002C）：验证默认值（test_mode=0）
//
//   Phase 5: 读取 spike 输出
//     - 读 OUT_FIFO_COUNT（0x4000_0020）：获取 output_fifo 中 spike 数量
//     - 循环读 OUT_FIFO_DATA（0x4000_001C）：逐个弹出并打印 spike_id
//
// -----------------------------------------------------------------------
// bit-plane 编码原理：
//
//   传统 SNN 用脉冲频率编码像素强度（intensity → spike rate）。
//   本 SoC 使用时间编码（temporal coding）：
//     - 8-bit 像素值 pixel_val[b] 展开为 8 个时间步
//     - 第 b 步（b=7 MSB 到 b=0 LSB）：若 pixel_val 的第 b 位 = 1，WL 激活
//   MSB 优先（b=7 先处理）：最高有效位对应最早的时间步（权重最大）
//
//   例：pixel_val = 0xA5 = 0b10100101
//     bit-plane 7: 1 → WL 激活
//     bit-plane 6: 0 → WL 不激活
//     bit-plane 5: 1 → WL 激活
//     ...
//     共 8 个 bit-plane，DMA 依次将它们送入 input_fifo
//
// -----------------------------------------------------------------------
// 测试数据说明：
//
//   wl_vec[0]：中心十字图案（8x8，64 bit）
//     逐行：行 0~1/6~7 全 0，行 2~5 中间 2 列有 1，行 3~4 全 6 列有 1
//     用于模拟 MNIST 数字"+"形状
//
//   wl_vec[1]：对角线 X 图案（备用，frames=1 时 wl_vec[1] 不实际使用）
//
//   pixel_val[t][p]：
//     若像素 p 在图案 t 中被激活（wl_vec[t][p]=1），像素值 = frame_amp[t]（0xFF 或 0x80）
//     否则像素值 = 0x00（不激活）
//
// -----------------------------------------------------------------------
// CIM_TEST_MODE：
//
//   当 cim_test_mode=1 时，cim_macro_blackbox 使用
//   cim_test_data_pos（ch 0~9）/ cim_test_data_neg（ch 10~19）作为合成 ADC 响应，
//   绕过真实 RRAM 读取逻辑。
//   用途：在没有真实 RRAM 模型的情况下验证控制路径通路。
//   本 TB 默认 cim_test_mode=0，使用真实 cim_macro_blackbox 行为模型。
//
// -----------------------------------------------------------------------
// 断言说明：
//
//   bitplane_shift 断言：确保 cim_ctrl 内部时步移位寄存器不越界
//     BITPLANE_W = $clog2(PIXEL_BITS)：移位寄存器宽度
//     BITPLANE_MAX = PIXEL_BITS-1：最大合法值（=7 for 8-bit 像素）
//
//   neuron_in_data X 断言：neuron_in_valid 拉高时，ADC 输出不应含 X
//     若含 X 说明 ADC/LIF 数据路径存在未初始化信号
//
// -----------------------------------------------------------------------
module top_tb;
  import snn_soc_pkg::*;
  import tb_bus_pkg::*;

  // -----------------------------------------------------------------------
  // 参数化常量（用于断言，不改变逻辑）
  // BITPLANE_W   : 时步移位寄存器的位宽（= ceil(log2(PIXEL_BITS))）
  //                例：PIXEL_BITS=8 → BITPLANE_W=3，移位寄存器范围 0~7
  // BITPLANE_MAX : 移位寄存器的最大合法值（= PIXEL_BITS-1 = 7）
  //                cim_ctrl 不应出现 bitplane_shift > 7 的情况
  // -----------------------------------------------------------------------
  localparam int BITPLANE_W = $clog2(PIXEL_BITS);
  localparam logic [BITPLANE_W-1:0] BITPLANE_MAX = BITPLANE_W'(PIXEL_BITS-1);

  logic clk;
  logic rst_n;

  // -----------------------------------------------------------------------
  // Stub 端口：连接 DUT 的外设接口，但 TB 不实际使用这些协议
  // uart_rx  : 保持 1'b1（UART 空闲电平，UART RX 低有效 start bit 为 0）
  // spi_miso : 保持 1'b0（SPI Master 未激活）
  // jtag_xxx : 保持 0（JTAG 未使用）
  // DUT 的 uart_tx, spi_cs_n 等输出通过 _unused_tb 消除 lint 警告
  // -----------------------------------------------------------------------
  // stub 端口
  logic uart_rx;
  logic uart_tx;
  logic spi_cs_n;
  logic spi_sck;
  logic spi_mosi;
  logic spi_miso;
  logic jtag_tck;
  logic jtag_tms;
  logic jtag_tdi;
  logic jtag_tdo;

  // -----------------------------------------------------------------------
  // DUT 实例化：snn_soc_top
  // 所有外设 IO 连接到 stub 信号，实际测试通过内部 bus_simple_if 进行
  // -----------------------------------------------------------------------
  snn_soc_top dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .uart_rx  (uart_rx),
    .uart_tx  (uart_tx),
    .spi_cs_n (spi_cs_n),
    .spi_sck  (spi_sck),
    .spi_mosi (spi_mosi),
    .spi_miso (spi_miso),
    .jtag_tck (jtag_tck),
    .jtag_tms (jtag_tms),
    .jtag_tdi (jtag_tdi),
    .jtag_tdo (jtag_tdo)
  );

  // -----------------------------------------------------------------------
  // 时钟生成：50MHz（周期 20ns）
  // 半周期 10ns → #10 翻转一次 → 完整周期 20ns
  // -----------------------------------------------------------------------
  // 时钟：50MHz（周期20ns）
  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;  // 半周期10ns -> 完整周期20ns = 50MHz
  end

  // -----------------------------------------------------------------------
  // 复位序列：
  //   - rst_n=0 保持 5 个时钟周期（100ns），确保所有 FF 复位到初始值
  //   - 同时将所有 stub 输入置为安全状态（避免 X 传播）
  //   - 5 拍后 rst_n=1，DUT 开始正常运行
  // -----------------------------------------------------------------------
  // 复位
  initial begin
    rst_n   = 1'b0;
    uart_rx = 1'b1; // UART 空闲电平（高电平）
    spi_miso= 1'b0;
    jtag_tck= 1'b0;
    jtag_tms= 1'b0;
    jtag_tdi= 1'b0;
    repeat (5) @(posedge clk); // 等待 5 个时钟沿（5×20ns = 100ns）
    rst_n = 1'b1;
  end

  // -----------------------------------------------------------------------
  // lint 消警：DUT 输出的 stub 信号通过异或拼接引用，避免"未使用信号"警告
  // uart_tx, spi_cs_n, spi_sck, spi_mosi, jtag_tdo 都是 DUT 的输出，
  // TB 不使用它们的值，但必须"引用"以通过 lint 检查
  // -----------------------------------------------------------------------
  // 标记未使用的 stub 输出，避免 lint 报警
  wire _unused_tb = uart_tx ^ spi_cs_n ^ spi_sck ^ spi_mosi ^ jtag_tdo;

  // -----------------------------------------------------------------------
  // FSDB 波形转储（Verdi/VCS 专用）
  //
  // $fsdbDumpfile: 设置波形文件路径（相对路径，需 waves/ 目录预先存在）
  // $fsdbDumpvars(0, top_tb): 转储 top_tb 及其所有子模块的信号（深度=0=全部）
  //
  // `ifndef VERILATOR 保护：Verilator 不支持 $fsdbDump* 系统任务，
  // 用条件编译宏跳过，避免 Verilator 仿真时报错。
  // VCS + Verdi 流程：确保在 Makefile/脚本中定义 PLI library 路径。
  // -----------------------------------------------------------------------
  // FSDB 波形（仅 VCS/Verdi 使用；Verilator 下屏蔽）
`ifndef VERILATOR
  initial begin
    $fsdbDumpfile("waves/snn_soc.fsdb");
    $fsdbDumpvars(0, top_tb);
  end
`endif

  // -----------------------------------------------------------------------
  // ADC 输出监控（背景 fork-join_none 进程）
  //
  // 两个 forever 进程并行运行，独立监控 ADC 状态：
  //
  // 进程 1（bl_sel 变化监控）：
  //   每拍检查 dut.u_adc.state，若非 IDLE 则打印：
  //     - ADC FSM 状态
  //     - 当前 BL 选择（bl_sel，20 通道选择器）
  //     - neuron_in_valid（是否有新的神经元输入）
  //     - bitplane_shift（当前处理的 bit-plane 序号）
  //   注意：直接通过 dut.u_adc.xxx 访问内部信号（层次化引用，仿真专用）
  //
  // 进程 2（neuron_in_valid 检测）：
  //   每拍检查 neuron_in_valid，一旦拉高则打印所有 NUM_OUTPUTS=10 个通道的
  //   有符号 ADC 输出值（Scheme B 差分结果，9-bit signed）
  //   $signed() 转换确保以有符号格式打印（否则默认无符号）
  //
  // fork-join_none：后台启动，不阻塞主测试进程
  // -----------------------------------------------------------------------
  // 监控 ADC 输出（用于 Smoke Test 验证）
  initial begin
    fork
      // 监控 bl_sel 变化
      forever begin
        @(posedge clk);
        if (dut.u_adc.state != 0) begin  // 不在 IDLE 状态时
          $display("[%0t] ADC: state=%0d, bl_sel=%0d, neuron_in_valid=%0b, bitplane_shift=%0d",
                   $time, dut.u_adc.state, dut.u_adc.bl_sel, dut.u_adc.neuron_in_valid, dut.u_cim_ctrl.bitplane_shift);
        end
      end

      // 监控 neuron_in_data 输出（Scheme B 有符号差分）
      forever begin
        @(posedge clk);
        if (dut.u_adc.neuron_in_valid) begin
          $display("========================================");
          $display("[%0t] ADC Output Valid! neuron_in_data (signed diff):", $time);
          for (int i = 0; i < NUM_OUTPUTS; i++) begin
            // 9-bit signed 差分值：正值=正权重激活，负值=负权重激活
            // %03X 以 3 位 16 进制显示原始位模式（方便与 Scheme B 公式对照）
            $display("  [%0d] = %0d (9'h%03X)",
                     i, $signed(dut.u_adc.neuron_in_data[i]), dut.u_adc.neuron_in_data[i]);
          end
          $display("========================================");
        end
      end
    join_none
  end

  // -----------------------------------------------------------------------
  // 关键断言（always 块，仅在 !SYNTHESIS 下编译）
  //
  // 断言 1：bitplane_shift 范围检查
  //   cim_ctrl 内部的 bitplane_shift 应在 [0, BITPLANE_MAX(=7)] 范围内
  //   越界说明时步状态机逻辑错误（如 reset 未清零或计数溢出）
  //   $fatal(1, ...) 在断言失败时立即终止仿真，避免带病运行产生误导结果
  //   /* verilator lint_off CMPCONST */：Verilator 认为 BITPLANE_MAX 是常量
  //     比较，可能给出"comparison is always true"的警告，此 pragma 消除该警告
  //
  // 断言 2：neuron_in_data X 检查
  //   neuron_in_valid 拉高时，每个 ADC 输出通道不应含 X 或 Z
  //   $isunknown() 检测 X/Z；$error 报错但不终止仿真（可继续观察后续行为）
  // -----------------------------------------------------------------------
`ifndef SYNTHESIS
  // 关键断言：有效拍输出不应包含 X，bitplane_shift 应合法
  /* verilator lint_off SYNCASYNCNET */
  always @(posedge clk) begin
    if (rst_n) begin
      /* verilator lint_off CMPCONST */
      assert (dut.u_cim_ctrl.bitplane_shift <= BITPLANE_MAX)
        else $fatal(1, "[TB] bitplane_shift 越界: %0d", dut.u_cim_ctrl.bitplane_shift);
      /* verilator lint_on CMPCONST */
      if (dut.u_adc.neuron_in_valid) begin
        for (int i = 0; i < NUM_OUTPUTS; i++) begin
          assert (!$isunknown(dut.u_adc.neuron_in_data[i]))
            else $error("[TB] neuron_in_data[%0d] 含 X", i);
        end
      end
    end
  end
  /* verilator lint_on SYNCASYNCNET */
`endif

  // -----------------------------------------------------------------------
  // 虚拟总线接口句柄
  //
  // bus_vif 是 bus_simple_if 类型的虚接口句柄。
  // top_tb 通过 dut.bus_if 获取 DUT 内部暴露的接口实例（层次化引用）。
  // initial 块中初始化所有 master 驱动信号为安全的初始值，避免 X 传播。
  // -----------------------------------------------------------------------
  // bus 虚接口句柄
  virtual bus_simple_if bus_vif;

  initial begin
    bus_vif = dut.bus_if; // 连接到 DUT 内部的 bus_simple_if 实例
    // 初始化 master 侧信号为无效状态（避免复位期间产生误操作）
    bus_vif.m_valid = 1'b0;
    bus_vif.m_write = 1'b0;
    bus_vif.m_addr  = 32'h0;
    bus_vif.m_wdata = 32'h0;
    bus_vif.m_wstrb = 4'h0;
  end

  // -----------------------------------------------------------------------
  // 主测试进程（initial block）
  //
  // 所有寄存器访问通过 bus_write32/bus_read32 任务进行（来自 tb_bus_pkg）。
  // 任务内部处理握手时序，此处只需关注测试逻辑。
  // -----------------------------------------------------------------------
  // 测试流程
  initial begin
    logic [31:0] rd;         // 通用读数据缓冲
    logic [31:0] word0;      // bit-plane 低 32-bit 暂存
    logic [31:0] word1;      // bit-plane 高 32-bit 暂存
    logic [NUM_INPUTS-1:0] wl_vec [0:1];          // 两个测试图案（64-bit 各一个）
    logic [7:0] pixel_val [0:1][0:NUM_INPUTS-1];  // 像素值：[帧][像素位置]
    logic [7:0] frame_amp [0:1];  // 每帧的振幅（8-bit 像素最大值）
    int frames = snn_soc_pkg::TIMESTEPS_DEFAULT; // 定版 T=10：同一输入重复 10 帧累积膜电位
    int write_idx;                // data_sram 写入索引（按 bit-plane 对计数）
    logic [NUM_INPUTS-1:0] plane_vec; // 当前 bit-plane 的 64-bit 位向量

    // -----------------------------------------------------------------------
    // 测试图案定义
    //
    // wl_vec[0]：中心十字（8×8=64 bit，每行 8 bit，共 8 行）
    //   bit 布局：bit[0]~bit[7] = 行 0（最低 8 bit），bit[56]~bit[63] = 行 7
    //   行 0（0b00000000）：全 0（无激活）
    //   行 1（0b00011000）：中间 2 列激活（列 3、列 4）
    //   行 2（0b00011000）：同上
    //   行 3（0b01111110）：中间 6 列激活（列 1~6）
    //   行 4（0b01111110）：同上
    //   行 5（0b00011000）：中间 2 列激活
    //   行 6（0b00011000）：同上
    //   行 7（0b00000000）：全 0
    //
    // wl_vec[1]：对角线 X（frames=1 时不实际传输，备用）
    // -----------------------------------------------------------------------
    // 8x8 patterns (used to build 8-bit pixels)
    // Pattern 0: 中心十字（8x8）
    wl_vec[0] = 64'b00000000_00011000_00011000_01111110_01111110_00011000_00011000_00000000;
    // Pattern 1: 对角线 X（备用，T=10 时 10 帧全部使用 Pattern 0 重复，Pattern 1 不用）
    wl_vec[1] = 64'b10000001_01000010_00100100_00011000_00011000_00100100_01000010_10000001;

    // -----------------------------------------------------------------------
    // 帧振幅设置
    // frame_amp[0] = 0xFF：所有激活像素的强度为 255（8 个 bit-plane 均激活）
    // frame_amp[1] = 0x80：仅 MSB（bit 7）激活，其余 bit-plane 为 0
    // -----------------------------------------------------------------------
    // Per-frame amplitude (8-bit)
    frame_amp[0] = 8'hFF; // all bits set
    frame_amp[1] = 8'h80; // MSB only

    // -----------------------------------------------------------------------
    // 像素值计算：将图案与振幅结合
    // pixel_val[t][p] = wl_vec[t][p] ? frame_amp[t] : 0
    // 即：激活位置的像素值 = 帧振幅；未激活位置 = 0
    // -----------------------------------------------------------------------
    for (int t = 0; t < 2; t = t + 1) begin
      for (int p = 0; p < NUM_INPUTS; p = p + 1) begin
        pixel_val[t][p] = wl_vec[t][p] ? frame_amp[t] : 8'h00;
      end
    end

    // 等待复位释放（rst_n 从 0 变为 1 后再等 1 拍，确保所有 FF 已复位完成）
    wait (rst_n == 1'b1);
    @(posedge clk);

    // =======================================================================
    // Phase 1: 寄存器配置
    // =======================================================================

    // 写 REG_THRESHOLD（0x4000_0000）：使用 snn_soc_pkg 中的默认值
    // THRESHOLD_DEFAULT 来自 snn_soc_pkg，确保与包参数一致
    // 1) 配置阈值与时步
    bus_write32(bus_vif, 32'h4000_0000, THRESHOLD_DEFAULT, 4'hF); // THRESHOLD
    // 写 REG_TIMESTEPS（0x4000_0004）：frames=TIMESTEPS_DEFAULT=10（定版），使用 wstrb=4'h1 只写 byte0
    bus_write32(bus_vif, 32'h4000_0004, frames,   4'h1); // TIMESTEPS

    // 读 REG_THRESHOLD_RATIO（0x4000_0024）：验证默认值
    // 期望值 = THRESHOLD_RATIO_DEFAULT = 4（ratio_code=4，4/255≈0.0157，定版锁定）
    // 读回 THRESHOLD_RATIO 验证默认值
    bus_read32(bus_vif, 32'h4000_0024, rd);
    $display("[TB] THRESHOLD_RATIO = %0d (expected %0d)", rd[7:0], THRESHOLD_RATIO_DEFAULT);

    // =======================================================================
    // Phase 2: 写入 data_sram（bit-plane 编码）
    //
    // 编码算法：
    //   对每帧 t（0..frames-1）：
    //     对每个 bit-plane b（PIXEL_BITS-1 下 to 0，MSB 先）：
    //       plane_vec[p] = pixel_val[t][p][b]（取每个像素的第 b 位）
    //       → 64 个像素的第 b 位拼成一个 64-bit 向量
    //       word0 = plane_vec[31:0]（低 32-bit）
    //       word1 = plane_vec[63:32]（高 32-bit）
    //       写入 data_sram：
    //         地址 0x0001_0000 + write_idx*8     → word0
    //         地址 0x0001_0000 + write_idx*8 + 4 → word1
    //       write_idx 递增
    //
    // 结果：data_sram 中存放了 frames*PIXEL_BITS 个 bit-plane，
    //        每个 bit-plane 占 8 字节（2 个 32-bit word）
    //        DMA 读取后重组为 64-bit wl_bitmap 送入 input_fifo
    // =======================================================================
    // 2) Write data_sram as bit-planes (MSB->LSB). Each plane is 64 bits = 2 words.
    write_idx = 0;
    for (int t = 0; t < frames; t = t + 1) begin
      for (int b = PIXEL_BITS-1; b >= 0; b = b - 1) begin
        // 提取第 b 位 bit-plane：64 个像素各取 1 bit 组成 64-bit 向量
        for (int p = 0; p < NUM_INPUTS; p = p + 1) begin
          // T=10：10 帧重复同一输入（pattern 0）进行膜电位累积
          // pixel_val 仅定义了 [0:1]，使用 t%2 防止越界；实际 smoke test 全部用 pattern 0
          plane_vec[p] = pixel_val[0][p][b];
        end
        word0 = plane_vec[31:0];   // 低 32-bit（像素 0~31 的第 b 位）
        word1 = plane_vec[63:32];  // 高 32-bit（像素 32~63 的第 b 位）
        // 写入 data_sram（物理地址 0x0001_0000 = data_sram 基址）
        // 步长：每个 bit-plane 占 8 字节（= write_idx * 8）
        bus_write32(bus_vif, 32'h0001_0000 + write_idx*8,     word0, 4'hF);
        bus_write32(bus_vif, 32'h0001_0000 + write_idx*8 + 4, word1, 4'hF);
        write_idx++;
      end
    end

    // =======================================================================
    // Phase 3: DMA 传输
    //
    // DMA 寄存器映射（相对于 dma_engine 挂载基址 0x4000_0100）：
    //   0x4000_0100 = DMA_SRC_ADDR  (offset 0x00)
    //   0x4000_0104 = DMA_LEN_WORDS (offset 0x04)
    //   0x4000_0108 = DMA_CTRL      (offset 0x08)
    //
    // DMA_LEN_WORDS = frames * PIXEL_BITS * 2
    //   = 10 * 8 * 2 = 160 words（160 是偶数，满足 DMA 的奇偶检查）
    //   每个 bit-plane 占 2 words，10帧×8 个 bit-plane，总计 160 words
    //
    // 轮询 DMA DONE（bit[1]）：
    //   DMA_CTRL[1] = done_sticky，传输完成后硬件置 1
    //   do-while 轮询：每次读 DMA_CTRL，直到 bit[1]=1
    // =======================================================================
    // 3) Start DMA
    bus_write32(bus_vif, 32'h4000_0100, 32'h0001_0000, 4'hF); // DMA_SRC_ADDR = data_sram 起始物理地址
    bus_write32(bus_vif, 32'h4000_0104, frames*PIXEL_BITS*2, 4'hF); // DMA_LEN_WORDS = frames*PIXEL_BITS*2
    bus_write32(bus_vif, 32'h4000_0108, 32'h1,         4'h1); // DMA_CTRL.START W1P：bit[0]=1 触发

    // 轮询 DMA DONE
    // rd[1] = DMA_CTRL.DONE（bit[1]）；= 1 时 DMA 完成
    do begin
      bus_read32(bus_vif, 32'h4000_0108, rd);
    end while (rd[1] == 1'b0);

    // =======================================================================
    // Phase 4: CIM 推理
    //
    // 写 CIM_CTRL.START（0x4000_0014，bit[0]，W1P）：触发 SNN 推理
    // 轮询 CIM_CTRL.DONE（bit[7]，W1C sticky）：等待推理完成
    //   done_sticky 由 snn_done_pulse 置 1，CPU 写 bit[7]=1 清零
    //   本 TB 在读到 DONE=1 后不清零（留供诊断，$finish 后自然消失）
    // =======================================================================
    // 4) 启动 CIM 推理
    bus_write32(bus_vif, 32'h4000_0014, 32'h1, 4'h1); // CIM_CTRL.START W1P：bit[0]=1 触发推理

    // 轮询 CIM DONE（bit7）
    // rd[7] = CIM_CTRL.DONE（done_sticky）；= 1 时推理完成
    do begin
      bus_read32(bus_vif, 32'h4000_0014, rd);
    end while (rd[7] == 1'b0);

    // -----------------------------------------------------------------------
    // Phase 4b: 读取诊断寄存器
    //
    // ADC_SAT_COUNT（0x4000_0028）：
    //   rdata = {adc_sat_low[31:16], adc_sat_high[15:0]}
    //   → rd[15:0]  = adc_sat_high（高饱和计数：ADC 输出 >= 正最大值的次数）
    //   → rd[31:16] = adc_sat_low （低饱和计数：ADC 输出 <= 负最大值的次数）
    //   注：字段名与位置的"反直觉"排列是设计选择，见 reg_bank.sv 注释
    //
    // DBG_CNT_0（0x4000_0030）：
    //   rdata[15:0]  = dma_frame_cnt（DMA 传输帧数）
    //   rdata[31:16] = cim_cycle_cnt（CIM 推理消耗时钟数）
    //
    // DBG_CNT_1（0x4000_0034）：
    //   rdata[15:0]  = spike_cnt  （输出 spike 总数）
    //   rdata[31:16] = wl_stall_cnt（WL 总线停顿次数）
    //
    // CIM_TEST（0x4000_002C）：
    //   rd[0]     = cim_test_mode（默认 0，未启用测试模式）
    //   rd[15:8]  = cim_test_data_pos（默认 0，ch 0~9）
    //   rd[23:16] = cim_test_data_neg（默认 0，ch 10~19）
    // -----------------------------------------------------------------------
    // 4b) 读取 ADC 饱和计数（诊断）
    bus_read32(bus_vif, 32'h4000_0028, rd);
    $display("[TB] ADC_SAT_COUNT = 0x%08X (sat_high=%0d, sat_low=%0d)",
             rd, rd[15:0], rd[31:16]);

    // 4c) 读取 Debug 计数器
    bus_read32(bus_vif, 32'h4000_0030, rd); // DBG_CNT_0
    $display("[TB] DBG_CNT_0 = 0x%08X (dma_frame=%0d, cim_cycle=%0d)",
             rd, rd[15:0], rd[31:16]);
    bus_read32(bus_vif, 32'h4000_0034, rd); // DBG_CNT_1
    $display("[TB] DBG_CNT_1 = 0x%08X (spike=%0d, wl_stall=%0d)",
             rd, rd[15:0], rd[31:16]);

    // 4d) 读取 CIM_TEST 寄存器（默认值应为 0）
    bus_read32(bus_vif, 32'h4000_002C, rd);
    $display("[TB] CIM_TEST = 0x%08X (test_mode=%0b, pos=0x%02X, neg=0x%02X)",
             rd, rd[0], rd[15:8], rd[23:16]);

    // =======================================================================
    // Phase 5: 读取 output_fifo 中的 spike 输出
    //
    // 流程：
    //   1. 读 OUT_FIFO_COUNT（0x4000_0020）：获取 spike 数量（最多 NUM_OUTPUTS=10）
    //   2. 循环读 OUT_FIFO_DATA（0x4000_001C）：逐个读取 spike_id
    //      - reg_bank 的 pop_pending 机制确保读后下一拍自动 pop
    //      - rd[3:0] = spike_id（4-bit，范围 0~9，对应 10 个输出神经元）
    //   3. 打印每个 spike_id
    //
    // 注意：此处的 rd（用于循环次数）是第一次读 OUT_COUNT 的值，
    //        若在读 spike 过程中 FIFO 状态变化（不应该，推理已完成），
    //        循环仍按初始 count 次数执行。
    //
    // 正常情况下（T=10，10帧累积）：output_fifo 中应有若干个激发神经元的 spike_id，
    //   每个 spike_id 对应一个膜电位超过阈值的输出神经元（数字分类结果）。
    // =======================================================================
    // 5) 读取 output_fifo
    bus_read32(bus_vif, 32'h4000_0020, rd); // OUT_FIFO_COUNT：当前 spike 数量
    $display("[TB] OUT_FIFO_COUNT = %0d", rd);

    // 逐个弹出并打印 spike_id
    for (int k = 0; k < rd; k = k + 1) begin
      bus_read32(bus_vif, 32'h4000_001C, word0); // OUT_FIFO_DATA：队头 spike_id（读触发 pop）
      $display("[TB] spike_id[%0d] = %0d", k, word0[3:0]); // 低 4-bit = spike_id
    end

    // -----------------------------------------------------------------------
    // 仿真结束
    // #100：等待 100ns（5 个时钟周期）让波形充分显示尾部状态
    // $finish：终止仿真，Verdi/VCS 会关闭 FSDB 文件
    // -----------------------------------------------------------------------
    // 结束仿真
    #100;
    $display("[TB] Simulation finished.");
    $finish;
  end
endmodule
