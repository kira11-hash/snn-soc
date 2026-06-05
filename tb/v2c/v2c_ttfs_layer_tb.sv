// Parity TB for v2c_ttfs_layer vs Python golden forward.ttfs_layer_forward (vectors from
// gen_ttfs_layer_vectors.py). Params via -D V2C_IN_DIM/OUT_DIM/W/T/EARLY.
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
`ifndef V2C_EARLY
 `define V2C_EARLY 0
`endif
`define V2C_DIR "sim/v2c/build/ttfs/"

module v2c_ttfs_layer_tb;
    localparam int IN_DIM  = `V2C_IN_DIM;
    localparam int OUT_DIM = `V2C_OUT_DIM;
    localparam int W       = `V2C_W;
    localparam int T       = `V2C_T;
    localparam int MEM_W   = 28;
    localparam int THR_W   = 28;
    localparam int PSUM_W  = 22;

    reg clk = 1'b0, rst_n = 1'b0, start = 1'b0;
    wire early_w = (`V2C_EARLY != 0);
    wire done;
    wire [$clog2(T+1)-1:0] n_steps;

    v2c_ttfs_layer #(.IN_DIM(IN_DIM), .OUT_DIM(OUT_DIM), .W(W), .T(T),
                     .PSUM_W(PSUM_W), .MEM_W(MEM_W), .THR_W(THR_W)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .early_exit(early_w),
        .done(done), .n_steps(n_steps));

    always #5 clk = ~clk;

    integer fd, code, exp_nsteps, o, exp_st, exp_mem, got_st, got_mem, errors;
    initial begin
        $readmemh({`V2C_DIR, "cells.hex"}, dut.cells_mem);
        $readmemh({`V2C_DIR, "spike.hex"}, dut.spike_mem);
        $readmemh({`V2C_DIR, "thr.hex"},   dut.thr_mem);
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1; @(posedge clk);
        start = 1'b1; @(posedge clk); start = 1'b0;
        wait (done); @(posedge clk);
        errors = 0;
        fd = $fopen({`V2C_DIR, "expected.txt"}, "r");
        if (fd == 0) begin $display("FATAL: cannot open expected.txt"); $finish; end
        code = $fscanf(fd, "%d\n", exp_nsteps);
        if (n_steps != exp_nsteps) begin
            errors = errors + 1; $display("  nsteps got=%0d exp=%0d", n_steps, exp_nsteps);
        end
        for (o = 0; o < OUT_DIM; o = o + 1) begin
            code = $fscanf(fd, "%d %d\n", exp_st, exp_mem);
            got_st  = (dut.spike_times[o] == T) ? -1 : dut.spike_times[o];   // T = no-spike -> Python -1
            got_mem = dut.membrane[o];                                       // signed -> sign-extend
            if (got_st != exp_st || got_mem != exp_mem) begin
                errors = errors + 1;
                if (errors <= 12)
                    $display("  o=%0d st got=%0d exp=%0d | mem got=%0d exp=%0d", o, got_st, exp_st, got_mem, exp_mem);
            end
        end
        $fclose(fd);
        if (errors == 0)
            $display("PASS v2c_ttfs_layer IN=%0d OUT=%0d W=%0d T=%0d early=%0d : %0d outputs + nsteps bit-exact",
                     IN_DIM, OUT_DIM, W, T, `V2C_EARLY, OUT_DIM);
        else
            $display("FAIL v2c_ttfs_layer IN=%0d OUT=%0d W=%0d T=%0d early=%0d : %0d errors",
                     IN_DIM, OUT_DIM, W, T, `V2C_EARLY, errors);
        $finish;
    end
endmodule
