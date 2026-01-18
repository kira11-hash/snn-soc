//======================================================================
// 文件名: bus_master_tasks.sv
// 描述: Testbench 使用的简化总线读写任务。
//======================================================================
package tb_bus_pkg;
  task automatic bus_write32(
    virtual bus_simple_if vif,
    input  logic [31:0] addr,
    input  logic [31:0] data,
    input  logic [3:0]  wstrb
  );
    // 发起写请求（1-cycle 响应）
    @(posedge vif.clk);
    vif.m_valid <= 1'b1;
    vif.m_write <= 1'b1;
    vif.m_addr  <= addr;
    vif.m_wdata <= data;
    vif.m_wstrb <= wstrb;

    @(posedge vif.clk);
    vif.m_valid <= 1'b0;
    vif.m_write <= 1'b0;
    vif.m_wstrb <= 4'h0;

    // 等待 ready
    while (vif.m_ready !== 1'b1) begin
      @(posedge vif.clk);
    end
  endtask

  task automatic bus_read32(
    virtual bus_simple_if vif,
    input  logic [31:0] addr,
    output logic [31:0] data
  );
    // 发起读请求（1-cycle 响应）
    @(posedge vif.clk);
    vif.m_valid <= 1'b1;
    vif.m_write <= 1'b0;
    vif.m_addr  <= addr;
    vif.m_wdata <= 32'h0;
    vif.m_wstrb <= 4'h0;

    @(posedge vif.clk);
    vif.m_valid <= 1'b0;
    vif.m_write <= 1'b0;

    // 等待 rvalid
    while (vif.m_rvalid !== 1'b1) begin
      @(posedge vif.clk);
    end
    data = vif.m_rdata;
  endtask
endpackage
