// -----------------------------------------------------------------------------
// AUTO-DOC-HEADER: Detailed readability notes for this file (comments only, no logic change)
// File: tb/tb_lib/bus_master_tasks.sv
// Purpose: Reusable bus read/write tasks for the simple bus interface used by top_tb.
// Role in system: Keeps testbench stimulus readable by hiding low-level valid/write/address handshake sequencing.
// Behavior summary: Task-based wrappers for register writes/reads with timing waits on the bus handshake.
// Simulation note: Task assignments in procedural context may trigger style warnings in lint but are acceptable for TB use.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
//======================================================================
// 文件名: bus_master_tasks.sv
// 描述: Testbench 使用的简化总线读写任务。
//======================================================================
//
// -----------------------------------------------------------------------
// 背景与接口说明：
//
//   本文件封装了对 bus_simple_if 接口的读写操作，供 top_tb.sv 调用。
//   bus_simple_if 的信号定义（参见 tb/tb_lib/bus_simple_if.sv）：
//     m_valid  : master 驱动，请求有效（写或读请求）
//     m_write  : master 驱动，1=写/0=读
//     m_addr   : master 驱动，字节地址（全 32-bit，bus_interconnect 做路由）
//     m_wdata  : master 驱动，写数据
//     m_wstrb  : master 驱动，字节使能（4-bit）
//     m_ready  : slave 回馈，写操作完成指示（1=本拍写入完成）
//     m_rvalid : slave 回馈，读数据有效（1=m_rdata 本拍有效）
//     m_rdata  : slave 回馈，读数据
//
//   bus_interconnect 的响应延迟：
//     写操作：m_valid+m_write 拉高后，bus_interconnect 在同拍或 1 拍后给出 m_ready=1
//             本任务写完后立即撤 m_valid，然后轮询 m_ready（通常 1 拍内完成）
//     读操作：m_valid 拉高后，bus_interconnect 在 1 拍流水线后给出 m_rvalid=1+m_rdata
//             本任务撤 m_valid 后轮询 m_rvalid
//
//   这两个任务的握手时序与 bus_interconnect 的"1-cycle 响应流水线"匹配。
//
// -----------------------------------------------------------------------
// 为什么用 package（tb_bus_pkg）：
//   SystemVerilog 的 automatic 任务需要在 package 或 module 中声明。
//   使用 package 后，top_tb 通过 import tb_bus_pkg::* 即可调用。
//   virtual interface 参数允许任务操作具体的接口实例（而非 hardcode）。
//
// -----------------------------------------------------------------------
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
package tb_bus_pkg;
  // -----------------------------------------------------------------------
  // task bus_write32：32-bit 寄存器写操作
  //
  // 参数：
  //   vif   : 虚拟总线接口句柄（由 top_tb 传入 dut.bus_if）
  //   addr  : 目标字节地址（全 32-bit 物理地址，bus_interconnect 负责路由）
  //   data  : 写入数据（32-bit）
  //   wstrb : 字节使能（4-bit，4'hF = 全字写）
  //
  // 时序（以时钟沿为单位）：
  //   Cycle N（@posedge 后）：
  //     驱动 m_valid=1, m_write=1, m_addr=addr, m_wdata=data, m_wstrb=wstrb
  //     → bus_interconnect 在同拍看到有效写请求
  //
  //   Cycle N+1（@posedge 后）：
  //     撤 m_valid=0, m_write=0, m_wstrb=4'h0
  //     → 1-cycle 写请求窗口关闭
  //
  //   然后 while 轮询 m_ready：
  //     → 若 bus_interconnect 已经在 N 或 N+1 拍置了 m_ready=1，循环不执行
  //     → 若 m_ready 还未到，等待到它变为 1
  //
  // 注意：任务使用 vif.m_xxx = 直接赋值（非 @posedge 内），这在仿真中等价于
  //       非阻塞赋值，赋值后立即在下一个 delta cycle 生效。
  // -----------------------------------------------------------------------
  task automatic bus_write32(
    virtual bus_simple_if vif,
    input  logic [31:0] addr,
    input  logic [31:0] data,
    input  logic [3:0]  wstrb
  );
    // 发起写请求（1-cycle 响应）
    @(posedge vif.clk);
    // 驱动请求信号：m_valid=1, m_write=1 通知 bus_interconnect 这是写操作
    vif.m_valid = 1'b1;
    vif.m_write = 1'b1;
    vif.m_addr  = addr;
    vif.m_wdata = data;
    vif.m_wstrb = wstrb;

    @(posedge vif.clk);
    // 撤销请求（只保持 1 拍有效），bus_interconnect 已经在 cycle N 看到请求
    vif.m_valid = 1'b0;
    vif.m_write = 1'b0;
    vif.m_wstrb = 4'h0;

    // 等待 ready
    // bus_interconnect 的 m_ready 通常在 cycle N 或 N+1 拍拉高
    // while 循环确保：若 ready 已经为 1（通常如此），循环体不执行；
    // 若 interconnect 有背压，任务会等待直到 ready
    while (vif.m_ready !== 1'b1) begin
      @(posedge vif.clk);
    end
  endtask

  // -----------------------------------------------------------------------
  // task bus_read32：32-bit 寄存器读操作
  //
  // 参数：
  //   vif   : 虚拟总线接口句柄
  //   addr  : 目标字节地址（全 32-bit 物理地址）
  //   data  : 输出参数，捕获读回的 32-bit 数据
  //
  // 时序（以时钟沿为单位）：
  //   Cycle N（@posedge 后）：
  //     驱动 m_valid=1, m_write=0, m_addr=addr
  //     → bus_interconnect 在同拍看到有效读请求，开始 1 拍流水准备 rdata
  //
  //   Cycle N+1（@posedge 后）：
  //     撤 m_valid=0
  //     → 读请求窗口关闭
  //
  //   然后 while 轮询 m_rvalid：
  //     → bus_interconnect 通常在 cycle N+1 或 N+2 给出 m_rvalid=1
  //     → 一旦 m_rvalid=1，捕获 m_rdata 到 data 输出
  //
  // 注意：
  //   - bus_read32 不使用 wstrb（读操作不需要字节使能），固定驱动 m_wstrb=4'h0
  //   - m_rdata 在 m_rvalid=1 的同拍有效，无需额外等待
  //   - data 是 output 参数，调用者（top_tb）通过 data 获取读回值
  //     例：bus_read32(bus_vif, ADDR, rd); → rd 即为读回数据
  // -----------------------------------------------------------------------
  task automatic bus_read32(
    virtual bus_simple_if vif,
    input  logic [31:0] addr,
    output logic [31:0] data
  );
    // 发起读请求（1-cycle 响应）
    @(posedge vif.clk);
    // 驱动读请求：m_valid=1, m_write=0 通知 bus_interconnect 这是读操作
    vif.m_valid = 1'b1;
    vif.m_write = 1'b0;
    vif.m_addr  = addr;
    vif.m_wdata = 32'h0; // 读操作写数据无意义，驱动为 0 保持总线干净
    vif.m_wstrb = 4'h0;  // 读操作不需要字节使能

    @(posedge vif.clk);
    // 撤销请求（只保持 1 拍有效）
    vif.m_valid = 1'b0;
    vif.m_write = 1'b0;

    // 等待 rvalid
    // bus_interconnect 将读请求流水处理，rvalid 在 1~2 拍后到来
    // while 循环等待直到 m_rvalid=1 才捕获数据
    while (vif.m_rvalid !== 1'b1) begin
      @(posedge vif.clk);
    end
    // m_rvalid=1 的同拍捕获读数据（总线保证此拍 m_rdata 有效）
    data = vif.m_rdata;
  endtask
endpackage
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */
