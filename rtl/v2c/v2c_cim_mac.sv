// =====================================================================================================
// v2c_cim_mac — V2C digital binary RRAM-CIM per-output MAC (popcount -> shift-add by codebook)
//
// Bit-exact golden: python_multilayer/v2c/encoding.mac (plan-v1.md「编码↔累积」表).
// V2C is a DIGITAL BINARY CIM: each bit-cell stores 1 bit; a weight is bit-sliced across W cells; the
// MAC is popcount/shift-add over the ACTIVE (spiking) rows — NO analog current sum, NO multi-bit ADC,
// 1-bit digital sense. This module computes ONE logical output's signed partial sum for one timestep.
//
//   cells_flat[k*IN_DIM +: IN_DIM] = bit-plane column k of this output (== python cells[:, out*W+k]).
//   pc_k = popcount(spikes & column_k)  (popcount over the active rows)
//     W=1 BNN     : psum = 2*pc0 - popcount(spikes)
//     W=2 ternary : psum = pc0(pos) - pc1(neg)
//     W>=4 2's-cmp: psum = sum_{k=0..W-2} 2^k*pc_k  -  2^(W-1)*pc_(W-1)   (MSB negated)
//
// Pure combinational. PSUM_W must hold +/- 2^(W-1)*IN_DIM. Synthesizable (popcount -> adder tree).
// =====================================================================================================
`default_nettype none

module v2c_cim_mac #(
    parameter int IN_DIM = 784,
    parameter int W      = 4,
    parameter int PSUM_W = 20                       // signed; >= clog2(2^(W-1)*IN_DIM)+2
) (
    input  wire [IN_DIM-1:0]        spikes,         // active rows this timestep
    input  wire [IN_DIM*W-1:0]      cells_flat,     // W bit-plane columns, column k = [k*IN_DIM +: IN_DIM]
    output reg  signed [PSUM_W-1:0] psum
);
    // popcount over IN_DIM bits (tool infers an adder tree; iverilog-friendly explicit reduction)
    function automatic [PSUM_W-1:0] popcount(input [IN_DIM-1:0] v);
        integer i;
        begin
            popcount = '0;
            for (i = 0; i < IN_DIM; i = i + 1) popcount = popcount + v[i];
        end
    endfunction

    function automatic [IN_DIM-1:0] col(input [IN_DIM*W-1:0] cf, input integer k);
        col = cf[k*IN_DIM +: IN_DIM];
    endfunction

    integer k;
    reg [PSUM_W-1:0] pc;
    always @* begin
        if (W == 1) begin
            psum = $signed(2 * popcount(spikes & col(cells_flat, 0))) - $signed(popcount(spikes));
        end else if (W == 2) begin
            psum = $signed(popcount(spikes & col(cells_flat, 0)))      // pos
                 - $signed(popcount(spikes & col(cells_flat, 1)));     // neg
        end else begin
            psum = '0;
            for (k = 0; k < W; k = k + 1) begin
                pc = popcount(spikes & col(cells_flat, k));
                if (k == W - 1) psum = psum - $signed(pc <<< k);       // MSB negated (two's-complement)
                else            psum = psum + $signed(pc <<< k);
            end
        end
    end
endmodule

`default_nettype wire
