// =====================================================================================================
// v2c_ramp_layer — V2C ramp (multi-bit / bit-serial) INPUT layer. Bit-exact golden:
//                  convert._ramp_hidden_times (the first layer of convert.eval_ttfs_ramp).
//
// The input pixel value v (in_bits) is fed bit-serially: z1[o] = sum_k 2^k * cim_mac(bitplane_k, w_o)
// (== integer v@w_int; cells stay binary — the input is UNSIGNED multi-bit, so NO input-side MSB
// negation; the weight sign is inside the codebook MAC). The hidden TTFS neuron then RAMPS that
// constant: membrane(t) = (t+1)*z1, first-spike at the first t with (t+1)*z1 >= threshold (z1>0 only).
// Divide-free: we accumulate membrane += z1 each timestep (== (t+1)*z1) instead of ceil(theta/z1).
//
// Phase A (COMPUTE_Z1): time-mux one v2c_cim_mac over (output o, input-bit k) -> z1[o].
// Phase B (RAMP)      : membrane += z1 each timestep, latch first-spike. FULL-FRAME (NO early-exit):
//   this is the INPUT/hidden layer — it must produce ALL hidden spike times for the next layer (golden
//   convert._ramp_hidden_times has no early-exit). First-spike early-exit belongs to the OUTPUT layer
//   (v2c_ttfs_layer). Per-neuron single-spike latch (fired) still gates re-firing.
// z1[o] / spike_times[o] exposed for parity (Phase A and Phase B checked independently).
// =====================================================================================================
`default_nettype none

module v2c_ramp_layer #(
    parameter int IN_DIM  = 784,
    parameter int OUT_DIM = 246,
    parameter int W       = 4,
    parameter int T       = 16,
    parameter int IN_BITS = 4,
    parameter int PSUM_W  = 20,                       // single-bitplane MAC width
    parameter int Z_W     = 26,                       // z1 = sum_k 2^k*mac_k (signed)
    parameter int MEM_W   = 32,                       // membrane = (t+1)*z1 (signed); T*|z1|
    parameter int THR_W   = 32
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start,
    output reg                     done,
    output reg  [$clog2(T+1)-1:0]  n_steps
);
    localparam int TW = $clog2(T + 1);

    reg [IN_DIM-1:0] cells_mem    [0:OUT_DIM*W-1];     // weight column c = cells[:, out*W+bit]
    reg [IN_DIM-1:0] bitplane_mem [0:IN_BITS-1];       // input bit k of every pixel (k-th bitplane)
    reg [THR_W-1:0]  thr_mem      [0:OUT_DIM-1];

    reg signed [Z_W-1:0]   z1          [0:OUT_DIM-1];
    reg signed [MEM_W-1:0] membrane    [0:OUT_DIM-1];
    reg        [TW-1:0]    spike_times [0:OUT_DIM-1];
    reg                    fired       [0:OUT_DIM-1];

    reg [$clog2(OUT_DIM+1)-1:0] o_idx;
    reg [$clog2(IN_BITS+1)-1:0] k_idx;
    reg [TW-1:0]                t_idx;
    reg signed [Z_W-1:0]        z_acc;                 // z1 accumulator across k for current o
    reg [2:0]                   state;
    localparam [2:0] S_IDLE=3'd0, S_Z1=3'd1, S_RAMP=3'd2, S_DONE=3'd3;

    // time-multiplexed MAC: output o's W weight columns × the current input bitplane k
    reg  [IN_DIM*W-1:0]      cells_flat;
    wire [IN_DIM-1:0]        bp = bitplane_mem[k_idx];
    wire signed [PSUM_W-1:0] mac_k;
    integer kk;
    always @* begin
        cells_flat = '0;
        for (kk = 0; kk < W; kk = kk + 1)
            cells_flat[kk*IN_DIM +: IN_DIM] = cells_mem[o_idx*W + kk];
    end
    v2c_cim_mac #(.IN_DIM(IN_DIM), .W(W), .PSUM_W(PSUM_W)) u_mac (
        .spikes(bp), .cells_flat(cells_flat), .psum(mac_k));

    wire signed [Z_W-1:0]   mac_k_sh  = $signed({{(Z_W-PSUM_W){mac_k[PSUM_W-1]}}, mac_k}) <<< k_idx;
    wire signed [MEM_W-1:0] z1_sext   = {{(MEM_W-Z_W){z1[o_idx][Z_W-1]}}, z1[o_idx]};
    wire signed [MEM_W-1:0] new_mem   = membrane[o_idx] + z1_sext;
    wire                    will_fire = !fired[o_idx] && (new_mem >= $signed({1'b0, thr_mem[o_idx]}));
    wire                    last_out  = (o_idx == OUT_DIM-1);
    wire                    last_bit  = (k_idx == IN_BITS-1);

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; done <= 1'b0; n_steps <= '0;
            o_idx <= '0; k_idx <= '0; t_idx <= '0; z_acc <= '0;
            for (i = 0; i < OUT_DIM; i = i + 1) begin
                z1[i] <= '0; membrane[i] <= '0; spike_times[i] <= T[TW-1:0]; fired[i] <= 1'b0;
            end
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        o_idx <= '0; k_idx <= '0; t_idx <= '0; z_acc <= '0;
                        for (i = 0; i < OUT_DIM; i = i + 1) begin
                            z1[i] <= '0; membrane[i] <= '0; spike_times[i] <= T[TW-1:0]; fired[i] <= 1'b0;
                        end
                        state <= S_Z1;
                    end
                end
                // ---- Phase A: z1[o] = sum_k 2^k * mac(bitplane_k, w_o) ----
                S_Z1: begin
                    if (last_bit) begin
                        z1[o_idx] <= z_acc + mac_k_sh;     // final accumulate for this output
                        z_acc <= '0; k_idx <= '0;
                        if (last_out) begin o_idx <= '0; t_idx <= '0; state <= S_RAMP; end
                        else o_idx <= o_idx + 1'b1;
                    end else begin
                        z_acc <= z_acc + mac_k_sh;
                        k_idx <= k_idx + 1'b1;
                    end
                end
                // ---- Phase B: ramp membrane += z1 each timestep, latch first spike ----
                S_RAMP: begin                              // FULL-FRAME (hidden layer): no early-exit
                    membrane[o_idx] <= new_mem;
                    if (will_fire) begin
                        fired[o_idx] <= 1'b1; spike_times[o_idx] <= t_idx;
                    end
                    if (last_out) begin
                        o_idx <= '0;
                        if (t_idx == T-1) begin n_steps <= t_idx + 1'b1; state <= S_DONE; end
                        else t_idx <= t_idx + 1'b1;
                    end else o_idx <= o_idx + 1'b1;
                end
                S_DONE: begin done <= 1'b1; state <= S_IDLE; end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
