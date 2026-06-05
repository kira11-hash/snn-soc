// Parity TB for v2c_ramp_layer vs convert._ramp_hidden_times (vectors from gen_ramp_layer_vectors.py).
// Checks z1[o] (Phase A) AND hidden spike_times[o] (Phase B). Params via -D.
`timescale 1ns/1ps
`ifndef V2C_IN_DIM
 `define V2C_IN_DIM 64
`endif
`ifndef V2C_OUT_DIM
 `define V2C_OUT_DIM 8
`endif
`ifndef V2C_W
 `define V2C_W 4
`endif
`ifndef V2C_T
 `define V2C_T 8
`endif
`ifndef V2C_IN_BITS
 `define V2C_IN_BITS 4
`endif
`define V2C_DIR "sim/v2c/build/ramp/"

module v2c_ramp_layer_tb;
    localparam int IN_DIM  = `V2C_IN_DIM;
    localparam int OUT_DIM = `V2C_OUT_DIM;
    localparam int W       = `V2C_W;
    localparam int T       = `V2C_T;
    localparam int IN_BITS = `V2C_IN_BITS;
    localparam int PSUM_W  = 22, Z_W = 28, MEM_W = 34, THR_W = 34;

    reg clk = 1'b0, rst_n = 1'b0, start = 1'b0;
    wire done;
    wire [$clog2(T+1)-1:0] n_steps;

    v2c_ramp_layer #(.IN_DIM(IN_DIM), .OUT_DIM(OUT_DIM), .W(W), .T(T), .IN_BITS(IN_BITS),
                     .PSUM_W(PSUM_W), .Z_W(Z_W), .MEM_W(MEM_W), .THR_W(THR_W)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .done(done), .n_steps(n_steps));

    always #5 clk = ~clk;

    integer fd, code, o, exp_z1, exp_st, got_z1, got_st, errors;
    initial begin
        $readmemh({`V2C_DIR, "cells.hex"},    dut.cells_mem);
        $readmemh({`V2C_DIR, "bitplane.hex"}, dut.bitplane_mem);
        $readmemh({`V2C_DIR, "thr.hex"},      dut.thr_mem);
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1; @(posedge clk);
        start = 1'b1; @(posedge clk); start = 1'b0;
        wait (done); @(posedge clk);
        errors = 0;
        fd = $fopen({`V2C_DIR, "expected.txt"}, "r");
        if (fd == 0) begin $display("FATAL: cannot open expected.txt"); $finish; end
        for (o = 0; o < OUT_DIM; o = o + 1) begin
            code = $fscanf(fd, "%d %d\n", exp_z1, exp_st);
            got_z1 = dut.z1[o];                                           // signed -> sign-extend
            got_st = (dut.spike_times[o] == T) ? -1 : dut.spike_times[o];
            if (got_z1 != exp_z1 || got_st != exp_st) begin
                errors = errors + 1;
                if (errors <= 12)
                    $display("  o=%0d z1 got=%0d exp=%0d | st got=%0d exp=%0d", o, got_z1, exp_z1, got_st, exp_st);
            end
        end
        $fclose(fd);
        if (errors == 0)
            $display("PASS v2c_ramp_layer IN=%0d OUT=%0d W=%0d T=%0d in_bits=%0d (full-frame) : z1+spike_times bit-exact",
                     IN_DIM, OUT_DIM, W, T, IN_BITS);
        else
            $display("FAIL v2c_ramp_layer IN=%0d OUT=%0d W=%0d T=%0d in_bits=%0d : %0d errors",
                     IN_DIM, OUT_DIM, W, T, IN_BITS, errors);
        $finish;
    end
endmodule
