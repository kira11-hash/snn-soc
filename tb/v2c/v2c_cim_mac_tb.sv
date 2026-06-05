// Parity TB for v2c_cim_mac vs the Python golden encoding.mac (vectors from gen_cim_mac_vectors.py).
// Compile-time params via -D V2C_IN_DIM / V2C_W / V2C_VEC (see sim/v2c/run_cim_mac.sh).
`timescale 1ns/1ps
`ifndef V2C_IN_DIM
 `define V2C_IN_DIM 64
`endif
`ifndef V2C_W
 `define V2C_W 4
`endif
`ifndef V2C_VEC
 `define V2C_VEC "sim/v2c/build/cim_mac.vec"
`endif

module v2c_cim_mac_tb;
    localparam int IN_DIM = `V2C_IN_DIM;
    localparam int W      = `V2C_W;
    localparam int PSUM_W = 24;

    reg  [IN_DIM-1:0]        spikes;
    reg  [IN_DIM*W-1:0]      cells_flat;
    wire signed [PSUM_W-1:0] psum;

    v2c_cim_mac #(.IN_DIM(IN_DIM), .W(W), .PSUM_W(PSUM_W)) dut (
        .spikes(spikes), .cells_flat(cells_flat), .psum(psum));

    integer fd, code, hdr_in, hdr_w, nlines, i, errors, expv, got;
    initial begin
        errors = 0;
        fd = $fopen(`V2C_VEC, "r");
        if (fd == 0) begin $display("FATAL: cannot open %s", `V2C_VEC); $finish; end
        code = $fscanf(fd, "%d %d %d\n", hdr_in, hdr_w, nlines);
        if (hdr_in != IN_DIM || hdr_w != W) begin
            $display("FATAL: vec header %0d/%0d != params %0d/%0d", hdr_in, hdr_w, IN_DIM, W); $finish;
        end
        for (i = 0; i < nlines; i = i + 1) begin
            code = $fscanf(fd, "%h %h %d\n", spikes, cells_flat, expv);
            if (code != 3) begin $display("FATAL: parse error at line %0d (code %0d)", i, code); $finish; end
            #1;
            got = psum;                                    // signed assign -> sign-extend to integer
            if (got != expv) begin
                errors = errors + 1;
                if (errors <= 10) $display("  MISMATCH line %0d: got=%0d expected=%0d", i, got, expv);
            end
        end
        $fclose(fd);
        if (errors == 0)
            $display("PASS v2c_cim_mac IN_DIM=%0d W=%0d : %0d vectors bit-exact vs encoding.mac", IN_DIM, W, nlines);
        else
            $display("FAIL v2c_cim_mac IN_DIM=%0d W=%0d : %0d / %0d mismatches", IN_DIM, W, errors, nlines);
        $finish;
    end
endmodule
