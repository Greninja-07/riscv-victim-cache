`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// muldiv_unit : RV32M multiplier / divider (multi-cycle, shared control)
//
//   funct3  op       meaning
//   000     MUL      rs1 * rs2           -> low  32 bits
//   001     MULH     signed   x signed   -> high 32 bits
//   010     MULHSU   signed   x unsigned -> high 32 bits
//   011     MULHU    unsigned x unsigned -> high 32 bits
//   100     DIV      signed   quotient
//   101     DIVU     unsigned quotient
//   110     REM      signed   remainder
//   111     REMU     unsigned remainder
//
// Handshake with the pipeline (all in the EX stage):
//   valid : an M-extension instruction (not squashed) is sitting in EX
//   done  : result is ready -> pipeline may let the instruction leave EX
//   advance : EX/MEM register is being loaded this cycle (instruction leaves EX)
//   The pipeline stalls while (valid && !done).
//
// Timing (iterative mode):   1 cycle latch + 32 cycles iterate + result cycle
// Timing (MUL_FAST=1):       MUL/MULH/MULHSU/MULHU use one DSP multiply:
//                            1 cycle latch + result cycle  (DIV/REM still iterative)
//
// Multiplier : radix-2 shift-add on a 33-bit signed multiplicand, last step
//              subtracts when the multiplier is signed (no sign fix-up needed)
// Divider    : restoring division on magnitudes, sign fix-up on the result,
//              RISC-V corner cases handled:
//                x / 0   = -1 (all ones)      x % 0 = x
//                INT_MIN / -1 = INT_MIN       INT_MIN % -1 = 0
//////////////////////////////////////////////////////////////////////////////
module muldiv_unit #(
    parameter MUL_FAST = 1
)(
    input         clk,
    input         reset_n,
    input         valid,
    input         advance,
    input  [2:0]  funct3,
    input  [31:0] a,            // rs1
    input  [31:0] b,            // rs2
    output reg    done,
    output [31:0] result
);

    localparam IDLE = 1'b0, RUN = 1'b1;

    reg        state;
    reg [5:0]  cnt;
    reg [2:0]  op;

    // ---------------- multiplier registers ----------------
    reg signed [32:0] ma;       // multiplicand (33-bit, sign/zero extended)
    reg signed [32:0] ph;       // partial product (high part)
    reg        [31:0] pl;       // partial product (low part) / multiplier
    reg               b_signed;

    // ---------------- divider registers -------------------
    reg [31:0] dq;              // dividend -> quotient
    reg [31:0] dr;              // remainder
    reg [31:0] dd;              // divisor magnitude
    reg        neg_q, neg_r;

    wire is_div = op[2];

    // ---------------- operand interpretation (at start) ---------------
    wire a_signed_now = (funct3 != 3'b011);                       // MUL,MULH,MULHSU: rs1 signed
    wire b_signed_now = (funct3 == 3'b000) || (funct3 == 3'b001); // MUL,MULH: rs2 signed
    wire div_signed   = ~funct3[0];                               // DIV, REM signed; DIVU, REMU unsigned
    wire a_neg        = div_signed & a[31];
    wire b_neg        = div_signed & b[31];
    wire [31:0] a_mag = a_neg ? (~a + 32'd1) : a;
    wire [31:0] b_mag = b_neg ? (~b + 32'd1) : b;
    wire b_zero       = (b == 32'd0);

    wire start = valid && !done && (state == IDLE);

    // ---------------- one multiplier step ----------------
    wire signed [32:0] ma_neg   = -ma;
    wire signed [32:0] addend33 = (cnt == 6'd31 && b_signed) ? ma_neg : ma;
    wire signed [33:0] mul_sum  = {ph[32], ph} + (pl[0] ? {addend33[32], addend33} : 34'sd0);

    // ---------------- one divider step -------------------
    wire [32:0] r_sh    = {dr, dq[31]};
    wire [33:0] r_diff  = {1'b0, r_sh} - {2'b00, dd};
    wire        r_ge    = ~r_diff[33];

    // ---------------- optional single-cycle (DSP) multiply ----
    wire signed [32:0] fa = {a_signed_now & a[31], a};
    wire signed [32:0] fb = {b_signed_now & b[31], b};
    wire signed [65:0] fprod = fa * fb;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE; cnt <= 6'd0; op <= 3'd0; done <= 1'b0;
            ma <= 33'sd0; ph <= 33'sd0; pl <= 32'd0; b_signed <= 1'b0;
            dq <= 32'd0; dr <= 32'd0; dd <= 32'd0; neg_q <= 1'b0; neg_r <= 1'b0;
        end else begin
            // instruction leaves EX -> clear result flag
            if (done && advance)
                done <= 1'b0;

            if (start) begin
                op  <= funct3;
                cnt <= 6'd0;
                if (funct3[2]) begin
                    // ---- division / remainder ----
                    dq    <= a_mag;
                    dr    <= 32'd0;
                    dd    <= b_mag;
                    neg_q <= div_signed & (a[31] ^ b[31]) & ~b_zero;
                    neg_r <= div_signed & a[31];
                    state <= RUN;
                end else if (MUL_FAST) begin
                    // ---- single cycle multiply ----
                    pl    <= fprod[31:0];
                    ph    <= {fprod[63], fprod[63:32]};
                    done  <= 1'b1;
                end else begin
                    // ---- iterative multiply ----
                    ma       <= {a_signed_now & a[31], a};
                    ph       <= 33'sd0;
                    pl       <= b;
                    b_signed <= b_signed_now;
                    state    <= RUN;
                end
            end else if (state == RUN) begin
                if (is_div) begin
                    dr <= r_ge ? r_diff[31:0] : r_sh[31:0];
                    dq <= {dq[30:0], r_ge};
                end else begin
                    ph <= mul_sum[33:1];
                    pl <= {mul_sum[0], pl[31:1]};
                end
                cnt <= cnt + 6'd1;
                if (cnt == 6'd31) begin
                    state <= IDLE;
                    done  <= 1'b1;
                end
            end
        end
    end

    // ---------------- result select (valid while done = 1) ----------------
    wire [31:0] q_out = neg_q ? (~dq + 32'd1) : dq;
    wire [31:0] r_out = neg_r ? (~dr + 32'd1) : dr;
    assign result = is_div ? (op[1] ? r_out : q_out)
                           : (op[1:0] == 2'b00 ? pl : ph[31:0]);

endmodule
