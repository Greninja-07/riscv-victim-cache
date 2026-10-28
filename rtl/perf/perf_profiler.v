`timescale 1ns / 1ps

// ============================================================================
// Module: perf_profiler
// Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher
// Author: Archit (Group 14)
//
// Description:
//   Synthesizable Hardware Performance Profiler for RV32I / RV32M Core with
//   2 KB direct-mapped L1 Data Cache, Victim Cache, and Prefetcher, targeting
//   the Digilent Nexys A7-100T FPGA board (Artix-7 XC7A100T, 100 MHz clock).
//
// Features:
//   - Six 32-bit saturating hardware event counters (cleared on rst).
//   - Sticky done-freeze register capturing final cycle execution statistics.
//   - 8-digit multiplexed 7-segment display driver with hex-to-7-segment decoder.
//   - Free-running refresh counter parameterizable via REFRESH_BITS.
//   - Active-low segment cathodes: seg[6:0] = {CG, CF, CE, CD, CC, CB, CA}.
//   - Active-low digit anodes: an[7:0] (only one digit enabled low at a time).
// ============================================================================

module perf_profiler #(
    parameter REFRESH_BITS = 19   // Free-running refresh counter width (~190 Hz at 100 MHz)
)(
    input  wire        clk,          // 100 MHz system clock
    input  wire        rst,          // Asynchronous active-high reset (matches l1_cache_controller.v)
    input  wire        done,         // Level input: program finished (e.g. halt/ebreak/end-PC)
    input  wire        mem_stall,    // Pipeline stalled by memory / L1 miss
    input  wire        l1_access,    // L1 data cache access strobe
    input  wire        l1_hit,       // L1 data cache hit strobe (matches l1_cache_controller.v port interface)
    input  wire        l1_miss,      // L1 data cache miss strobe
    input  wire        victim_hit,   // Hit in victim cache
    input  wire        prefetch_hit, // Useful prefetch hit
    input  wire [2:0]  sw,           // Slide switch counter selector [2:0]
    input  wire [31:0] custom_val,   // Custom operation result display value (sw=110)
    output reg  [6:0]  seg,          // Active-low cathodes: {CG, CF, CE, CD, CC, CB, CA}
    output reg  [7:0]  an,           // Active-low digit anodes: an[7]=leftmost, an[0]=rightmost
    output wire        dp,           // Decimal point cathode (tied to 1'b1 = inactive/off)
    output reg         frozen        // Sticky freeze flag: 1 once done is asserted, cleared on rst
);

    // ------------------------------------------------------------------------
    // Note on l1_hit input port:
    // l1_hit is provided for exact port compatibility with l1_cache_controller.v.
    // Per design specifications, L1 hits are not tracked in a separate counter;
    // only the six architectural counters below are instantiated.
    // ------------------------------------------------------------------------

    // ------------------------------------------------------------------------
    // Hardware Performance Counters (Six 32-bit Registers)
    // ------------------------------------------------------------------------
    // 0: total_cycles  : Increments every clock cycle while not frozen
    // 1: stall_cycles  : Increments when mem_stall is asserted while not frozen
    // 2: l1_accesses   : Increments on l1_access while not frozen
    // 3: l1_misses     : Increments on l1_miss while not frozen
    // 4: victim_hits   : Increments on victim_hit while not frozen
    // 5: prefetch_hits : Increments on prefetch_hit while not frozen
    // All counters saturate at 32'hFFFFFFFF instead of overflowing/wrapping.
    // ------------------------------------------------------------------------
    reg [31:0] total_cycles;
    reg [31:0] stall_cycles;
    reg [31:0] l1_accesses;
    reg [31:0] l1_misses;
    reg [31:0] victim_hits;
    reg [31:0] prefetch_hits;

    // ------------------------------------------------------------------------
    // DONE-FREEZE & Event Counting Sequential Logic
    // ------------------------------------------------------------------------
    // Reset polarity: Asynchronous active-high reset (rst), identical to
    // l1_cache_controller.v ("always @(posedge clk or posedge rst)").
    //
    // Off-by-one convention:
    // - On the clock cycle where done is first observed high while !frozen,
    //   frozen <= 1'b1 is scheduled for the next clock edge.
    // - Concurrently, during that exact cycle, !frozen is true, so all event
    //   counters evaluate their conditions and capture that cycle's activity
    //   (e.g., total_cycles increments and counts the cycle done is first seen).
    // - On subsequent clock cycles, frozen remains 1'b1 (sticky register),
    //   blocking further increments and holding all counter values stable
    //   until rst is asserted.
    // ------------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            frozen        <= 1'b0;
            total_cycles  <= 32'd0;
            stall_cycles  <= 32'd0;
            l1_accesses   <= 32'd0;
            l1_misses     <= 32'd0;
            victim_hits   <= 32'd0;
            prefetch_hits <= 32'd0;
        end else begin
            if (!frozen) begin
                if (done) begin
                    frozen <= 1'b1;
                end

                // Saturating counter increments
                if (total_cycles != 32'hFFFFFFFF)
                    total_cycles <= total_cycles + 1'b1;

                if (mem_stall && (stall_cycles != 32'hFFFFFFFF))
                    stall_cycles <= stall_cycles + 1'b1;

                if (l1_access && (l1_accesses != 32'hFFFFFFFF))
                    l1_accesses <= l1_accesses + 1'b1;

                if (l1_miss && (l1_misses != 32'hFFFFFFFF))
                    l1_misses <= l1_misses + 1'b1;

                if (victim_hit && (victim_hits != 32'hFFFFFFFF))
                    victim_hits <= victim_hits + 1'b1;

                if (prefetch_hit && (prefetch_hits != 32'hFFFFFFFF))
                    prefetch_hits <= prefetch_hits + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Counter Multiplexer (Switch Select sw[2:0])
    // ------------------------------------------------------------------------
    // sw[2:0] selects which 32-bit counter value is routed to the 7-segment display:
    //   3'b000 : Counter 0 - total_cycles
    //   3'b001 : Counter 1 - stall_cycles
    //   3'b010 : Counter 2 - l1_accesses
    //   3'b011 : Counter 3 - l1_misses
    //   3'b100 : Counter 4 - victim_hits
    //   3'b101 : Counter 5 - prefetch_hits
    //   3'b110 : Unused position - displays 32'h00000000
    //   3'b111 : Unused position - displays 32'hFFFFFFFF
    // ------------------------------------------------------------------------
    reg [31:0] disp_val;
    always @(*) begin
        case (sw)
            3'b000:  disp_val = total_cycles;
            3'b001:  disp_val = stall_cycles;
            3'b010:  disp_val = l1_accesses;
            3'b011:  disp_val = l1_misses;
            3'b100:  disp_val = victim_hits;
            3'b101:  disp_val = prefetch_hits;
            3'b110:  disp_val = custom_val;
            3'b111:  disp_val = 32'hFFFFFFFF;
            default: disp_val = 32'h00000000;
        endcase
    end

    // ------------------------------------------------------------------------
    // 7-Segment Display Time-Multiplexing Driver
    // ------------------------------------------------------------------------
    // A free-running counter is used to time-multiplex the 8 physical digits.
    // With REFRESH_BITS = 19 at 100 MHz:
    //   Full refresh rate = 100,000,000 / 2^19 ≈ 190.73 Hz (flicker-free).
    // The top 3 bits [REFRESH_BITS-1 : REFRESH_BITS-3] select the active digit.
    //
    // Digit Mapping:
    //   Digit 7 = Most Significant Hex Nibble disp_val[31:28], displayed on
    //             the leftmost display (an[7] active-low).
    //   Digit 0 = Least Significant Hex Nibble disp_val[3:0], displayed on
    //             the rightmost display (an[0] active-low).
    //   Exactly one anode bit is asserted low at any given time.
    // ------------------------------------------------------------------------
    reg [REFRESH_BITS-1:0] refresh_counter;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            refresh_counter <= {REFRESH_BITS{1'b0}};
        end else begin
            refresh_counter <= refresh_counter + 1'b1;
        end
    end

    wire [2:0] digit_sel = refresh_counter[REFRESH_BITS-1 : REFRESH_BITS-3];

    // Select active 4-bit nibble based on active digit
    reg [3:0] hex_digit;
    always @(*) begin
        case (digit_sel)
            3'd0: hex_digit = disp_val[3:0];    // Rightmost digit (an[0])
            3'd1: hex_digit = disp_val[7:4];
            3'd2: hex_digit = disp_val[11:8];
            3'd3: hex_digit = disp_val[15:12];
            3'd4: hex_digit = disp_val[19:16];
            3'd5: hex_digit = disp_val[23:20];
            3'd6: hex_digit = disp_val[27:24];
            3'd7: hex_digit = disp_val[31:28];  // Leftmost digit (an[7])
            default: hex_digit = 4'h0;
        endcase
    end

    // Active-low anode decoder: exactly one bit low at a time
    always @(*) begin
        case (digit_sel)
            3'd0: an = 8'b11111110;
            3'd1: an = 8'b11111101;
            3'd2: an = 8'b11111011;
            3'd3: an = 8'b11110111;
            3'd4: an = 8'b11101111;
            3'd5: an = 8'b11011111;
            3'd6: an = 8'b10111111;
            3'd7: an = 8'b01111111;
            default: an = 8'b11111111;
        endcase
    end

    // ------------------------------------------------------------------------
    // Hexadecimal to 7-Segment Decoder Function
    // ------------------------------------------------------------------------
    // Active-low cathode mapping:
    //   seg[6] = CG (Center segment)
    //   seg[5] = CF (Upper-left vertical)
    //   seg[4] = CE (Lower-left vertical)
    //   seg[3] = CD (Bottom horizontal)
    //   seg[2] = CC (Lower-right vertical)
    //   seg[1] = CB (Upper-right vertical)
    //   seg[0] = CA (Top horizontal)
    //
    // Logical 0 illuminates the segment; logical 1 turns the segment off.
    // ------------------------------------------------------------------------
    function [6:0] hex_to_7seg;
        input [3:0] hex;
        begin
            case (hex)
                4'h0: hex_to_7seg = 7'b1000000; // 0: CA,CB,CC,CD,CE,CF on; CG off
                4'h1: hex_to_7seg = 7'b1111001; // 1: CB,CC on
                4'h2: hex_to_7seg = 7'b0100100; // 2: CA,CB,CD,CE,CG on
                4'h3: hex_to_7seg = 7'b0110000; // 3: CA,CB,CC,CD,CG on
                4'h4: hex_to_7seg = 7'b0011001; // 4: CB,CC,CF,CG on
                4'h5: hex_to_7seg = 7'b0010010; // 5: CA,CC,CD,CF,CG on
                4'h6: hex_to_7seg = 7'b0000010; // 6: CA,CC,CD,CE,CF,CG on
                4'h7: hex_to_7seg = 7'b1111000; // 7: CA,CB,CC on
                4'h8: hex_to_7seg = 7'b0000000; // 8: All segments on
                4'h9: hex_to_7seg = 7'b0010000; // 9: CA,CB,CC,CD,CF,CG on
                4'hA: hex_to_7seg = 7'b0001000; // A: CA,CB,CC,CE,CF,CG on
                4'hB: hex_to_7seg = 7'b0000011; // b: CC,CD,CE,CF,CG on
                4'hC: hex_to_7seg = 7'b1000110; // C: CA,CD,CE,CF on
                4'hD: hex_to_7seg = 7'b0100001; // d: CB,CC,CD,CE,CG on
                4'hE: hex_to_7seg = 7'b0000110; // E: CA,CD,CE,CF,CG on
                4'hF: hex_to_7seg = 7'b0001110; // F: CA,CE,CF,CG on
                default: hex_to_7seg = 7'b1111111; // All segments off
            endcase
        end
    endfunction

    always @(*) begin
        seg = hex_to_7seg(hex_digit);
    end

    // Decimal point is tied off to 1'b1 (inactive/off for all digits)
    assign dp = 1'b1;

endmodule

// ============================================================================
// Top-Level Instantiation Example (Commented Reference)
// ============================================================================
// Example hookup in top_fpga.v or system-level integration:
//
// perf_profiler #(
//     .REFRESH_BITS (19)
// ) u_perf_profiler (
//     .clk          (clk),
//     .rst          (rst),
//     .done         (done),
//     .mem_stall    (cpu_stall),
//     .l1_access    (l1_access),
//     .l1_hit       (l1_hit),
//     .l1_miss      (l1_miss),
//     .victim_hit   (1'b0), // replace tie-offs when victim_cache.v / prefetcher.v are integrated
//     .prefetch_hit (1'b0), // replace tie-offs when victim_cache.v / prefetcher.v are integrated
//     .sw           (sw[2:0]),
//     .seg          (seg[6:0]),
//     .an           (an[7:0]),
//     .dp           (dp),
//     .frozen       (frozen)
// );
// ============================================================================
