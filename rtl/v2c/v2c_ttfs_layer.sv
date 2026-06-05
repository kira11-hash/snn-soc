// =====================================================================================================
// v2c_ttfs_layer — V2C TTFS-IF FC layer (integrate -> per-output integer threshold -> first-spike latch
//                  -> first-spike early-exit). Bit-exact golden: forward.ttfs_layer_forward.
//
// Per timestep t (0..T-1): membrane[o] += cim_mac(spike_stream[t], cells_of_output_o); a not-yet-fired
// output fires (latches spike_time=t) the FIRST step its membrane >= threshold[o]; with early_exit the
// layer stops at the end of the first timestep at which ANY output has fired (single-spike TTFS).
//
// Datapath: ONE time-multiplexed v2c_cim_mac processes one output per cycle (area-optimal). Functional
// result (spike_times/membrane/n_steps) is independent of the datapath width; a wider stripe (LANES =
// 128/W per plan-v1.md) is a latency knob added later — parity here pins the function. Memories
// (cells/spikes/threshold) are behavioral for parity; in silicon cells live in the RRAM macro and
// spikes/θ in BRAM (loaded by the P&V / loader path).
// =====================================================================================================
`default_nettype none

module v2c_ttfs_layer #(
    parameter int IN_DIM  = 784,
    parameter int OUT_DIM = 246,
    parameter int W       = 4,
    parameter int T       = 16,
    parameter int PSUM_W  = 20,
    parameter int MEM_W   = 24,                       // signed membrane; holds T * max|psum|
    parameter int THR_W   = 24                        // per-output integer threshold (positive)
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start,             // 1-cycle pulse: begin a frame
    input  wire                    early_exit,        // 1 = stop at first fired (deployed); 0 = full T
    output reg                     done,
    output reg  [$clog2(T+1)-1:0]  n_steps            // timesteps actually run
);
    localparam int TW = $clog2(T + 1);                // spike-time width (value T = "no spike")

    // ---- behavioral memories (TB loads via $readmemh; synth -> RRAM macro + BRAM) -------------------
    reg [IN_DIM-1:0] cells_mem [0:OUT_DIM*W-1];        // column c = cells[:, c] (c = out*W + bit)
    reg [IN_DIM-1:0] spike_mem [0:T-1];               // spike_stream[t]
    reg [THR_W-1:0]  thr_mem   [0:OUT_DIM-1];         // per-output integer threshold

    // ---- state (TB reads spike_times/membrane/fired hierarchically) --------------------------------
    reg signed [MEM_W-1:0] membrane   [0:OUT_DIM-1];
    reg        [TW-1:0]    spike_times [0:OUT_DIM-1];  // = t when fired, else T
    reg                    fired       [0:OUT_DIM-1];
    reg                    any_fired;

    reg [TW-1:0]              t_idx;                    // current timestep
    reg [$clog2(OUT_DIM+1)-1:0] o_idx;                 // current output within the timestep
    reg [1:0]                state;
    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_DONE = 2'd2;

    // ---- combinational MAC for the current output (time-multiplexed) --------------------------------
    reg  [IN_DIM*W-1:0]      cells_flat;
    wire signed [PSUM_W-1:0] psum;
    integer kk;
    always @* begin
        cells_flat = '0;
        for (kk = 0; kk < W; kk = kk + 1)
            cells_flat[kk*IN_DIM +: IN_DIM] = cells_mem[o_idx*W + kk];
    end
    v2c_cim_mac #(.IN_DIM(IN_DIM), .W(W), .PSUM_W(PSUM_W)) u_mac (
        .spikes(spike_mem[t_idx]), .cells_flat(cells_flat), .psum(psum));

    wire signed [MEM_W-1:0] psum_sext = {{(MEM_W-PSUM_W){psum[PSUM_W-1]}}, psum};
    wire signed [MEM_W-1:0] new_mem   = membrane[o_idx] + psum_sext;
    wire                    will_fire = !fired[o_idx] && (new_mem >= $signed({1'b0, thr_mem[o_idx]}));
    wire                    last_out  = (o_idx == OUT_DIM-1);

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; done <= 1'b0; n_steps <= '0; any_fired <= 1'b0;
            t_idx <= '0; o_idx <= '0;
            for (i = 0; i < OUT_DIM; i = i + 1) begin
                membrane[i] <= '0; spike_times[i] <= T[TW-1:0]; fired[i] <= 1'b0;
            end
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        any_fired <= 1'b0; t_idx <= '0; o_idx <= '0;
                        for (i = 0; i < OUT_DIM; i = i + 1) begin
                            membrane[i] <= '0; spike_times[i] <= T[TW-1:0]; fired[i] <= 1'b0;
                        end
                        state <= S_RUN;
                    end
                end
                S_RUN: begin
                    membrane[o_idx] <= new_mem;                       // integrate this output
                    if (will_fire) begin
                        fired[o_idx] <= 1'b1; spike_times[o_idx] <= t_idx; any_fired <= 1'b1;
                    end
                    if (last_out) begin                              // finished all outputs for step t
                        o_idx <= '0;
                        if ((early_exit && (any_fired || will_fire)) || (t_idx == T-1)) begin
                            n_steps <= t_idx + 1'b1; state <= S_DONE;
                        end else begin
                            t_idx <= t_idx + 1'b1;
                        end
                    end else begin
                        o_idx <= o_idx + 1'b1;
                    end
                end
                S_DONE: begin done <= 1'b1; state <= S_IDLE; end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
