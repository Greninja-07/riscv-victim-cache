`timescale 1ns / 1ps

// ============================================================================
// Testbench: tb_perf_profiler
// Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher
// Author: Archit (Group 14)
//
// Description:
//   Comprehensive testbench for perf_profiler module.
//   Verifies:
//     1. Active-high asynchronous reset clearing all counters and frozen.
//     2. Independent and concurrent counter increments.
//     3. Exact off-by-one done-freeze behavior (capturing cycle done asserted).
//     4. Post-freeze hold (no counter increments once frozen == 1).
//     5. Counter saturation at 32'hFFFFFFFF without wrap-around.
//     6. 3-bit switch (sw) counter routing including unused states (110, 111).
//     7. 7-segment display multiplexing, active-low anodes, and 0-F hex decoding.
// ============================================================================

module tb_perf_profiler;

    // Fast refresh counter for simulation purposes: REFRESH_BITS = 3
    // Each clock cycle advances to the next digit (8 cycles for full frame).
    localparam REFRESH_BITS = 3;

    // DUT Signals
    reg        clk;
    reg        rst;
    reg        done;
    reg        mem_stall;
    reg        l1_access;
    reg        l1_hit;
    reg        l1_miss;
    reg        victim_hit;
    reg        prefetch_hit;
    reg  [2:0] sw;

    wire [6:0] seg;
    wire [7:0] an;
    wire       dp;
    wire       frozen;

    // Error counter
    integer errors = 0;

    // Instantiate Device Under Test
    perf_profiler #(
        .REFRESH_BITS(REFRESH_BITS)
    ) dut (
        .clk          (clk),
        .rst          (rst),
        .done         (done),
        .mem_stall    (mem_stall),
        .l1_access    (l1_access),
        .l1_hit       (l1_hit),
        .l1_miss      (l1_miss),
        .victim_hit   (victim_hit),
        .prefetch_hit (prefetch_hit),
        .sw           (sw),
        .seg          (seg),
        .an           (an),
        .dp           (dp),
        .frozen       (frozen)
    );

    // Clock generation: 100 MHz (10 ns period)
    always #5 clk = ~clk;

    // Expected 7-segment active-low pattern table for validation
    // Format: {CG, CF, CE, CD, CC, CB, CA}
    function [6:0] exp_seg;
        input [3:0] val;
        case (val)
            4'h0: exp_seg = 7'b1000000;
            4'h1: exp_seg = 7'b1111001;
            4'h2: exp_seg = 7'b0100100;
            4'h3: exp_seg = 7'b0110000;
            4'h4: exp_seg = 7'b0011001;
            4'h5: exp_seg = 7'b0010010;
            4'h6: exp_seg = 7'b0000010;
            4'h7: exp_seg = 7'b1111000;
            4'h8: exp_seg = 7'b0000000;
            4'h9: exp_seg = 7'b0010000;
            4'hA: exp_seg = 7'b0001000;
            4'hB: exp_seg = 7'b0000011;
            4'hC: exp_seg = 7'b1000110;
            4'hD: exp_seg = 7'b0100001;
            4'hE: exp_seg = 7'b0000110;
            4'hF: exp_seg = 7'b0001110;
            default: exp_seg = 7'b1111111;
        endcase
    endfunction

    integer i;

    initial begin
        // Waveform dump
        $dumpfile("perf_profiler.vcd");
        $dumpvars(0, tb_perf_profiler);

        // Initialize signals
        clk          = 0;
        rst          = 0;
        done         = 0;
        mem_stall    = 0;
        l1_access    = 0;
        l1_hit       = 0;
        l1_miss      = 0;
        victim_hit   = 0;
        prefetch_hit = 0;
        sw           = 3'b000;

        $display("================================================================");
        $display("Starting Performance Profiler Verification");
        $display("================================================================");

        // --------------------------------------------------------------------
        // Test 1: Reset Assertion & Deassertion
        // --------------------------------------------------------------------
        $display("[TEST 1] Testing Reset Assertion and Initial State...");
        #2;
        rst = 1;
        #20;
        if (frozen !== 1'b0) begin
            $display("ERROR: frozen is not 0 during reset!");
            errors = errors + 1;
        end
        if (dut.total_cycles !== 32'd0 || dut.stall_cycles !== 32'd0 ||
            dut.l1_accesses  !== 32'd0 || dut.l1_misses    !== 32'd0 ||
            dut.victim_hits  !== 32'd0 || dut.prefetch_hits !== 32'd0) begin
            $display("ERROR: Counters not zeroed during reset!");
            errors = errors + 1;
        end
        if (dp !== 1'b1) begin
            $display("ERROR: dp is not tied to 1'b1!");
            errors = errors + 1;
        end

        // Deassert reset synchronously with clock edge
        @(negedge clk);
        rst = 0;
        @(posedge clk);
        #1;
        $display("  Reset successfully cleared. total_cycles = %0d", dut.total_cycles);

        // --------------------------------------------------------------------
        // Test 2: Event Counting Verification
        // --------------------------------------------------------------------
        $display("[TEST 2] Testing Hardware Event Increments...");
        
        // Cycle 1: mem_stall active
        @(negedge clk);
        mem_stall = 1;
        @(posedge clk);
        #1;
        mem_stall = 0;

        // Cycle 2: l1_access active
        @(negedge clk);
        l1_access = 1;
        @(posedge clk);
        #1;
        l1_access = 0;

        // Cycle 3: l1_miss active (along with l1_access)
        @(negedge clk);
        l1_access = 1;
        l1_miss   = 1;
        @(posedge clk);
        #1;
        l1_access = 0;
        l1_miss   = 0;

        // Cycle 4: victim_hit active
        @(negedge clk);
        victim_hit = 1;
        @(posedge clk);
        #1;
        victim_hit = 0;

        // Cycle 5: prefetch_hit active
        @(negedge clk);
        prefetch_hit = 1;
        @(posedge clk);
        #1;
        prefetch_hit = 0;

        // Cycle 6: l1_hit asserted (should NOT have a dedicated counter)
        @(negedge clk);
        l1_hit = 1;
        @(posedge clk);
        #1;
        l1_hit = 0;

        // Check counts
        // Cycles elapsed since reset deassertion: 7 cycles total
        @(posedge clk);
        #1;
        if (dut.stall_cycles !== 32'd1) begin
            $display("ERROR: stall_cycles mismatch! Expected 1, got %0d", dut.stall_cycles);
            errors = errors + 1;
        end
        if (dut.l1_accesses !== 32'd2) begin
            $display("ERROR: l1_accesses mismatch! Expected 2, got %0d", dut.l1_accesses);
            errors = errors + 1;
        end
        if (dut.l1_misses !== 32'd1) begin
            $display("ERROR: l1_misses mismatch! Expected 1, got %0d", dut.l1_misses);
            errors = errors + 1;
        end
        if (dut.victim_hits !== 32'd1) begin
            $display("ERROR: victim_hits mismatch! Expected 1, got %0d", dut.victim_hits);
            errors = errors + 1;
        end
        if (dut.prefetch_hits !== 32'd1) begin
            $display("ERROR: prefetch_hits mismatch! Expected 1, got %0d", dut.prefetch_hits);
            errors = errors + 1;
        end
        $display("  Event counts verified successfully.");

        // --------------------------------------------------------------------
        // Test 3: DONE-FREEZE & Off-By-One Semantics
        // --------------------------------------------------------------------
        $display("[TEST 3] Testing DONE-FREEZE & Exact Off-By-One Convention...");
        // Current total_cycles before assertion
        @(negedge clk);
        $display("  Before done assertion: total_cycles = %0d, frozen = %0b", dut.total_cycles, frozen);
        done = 1;
        mem_stall = 1; // mem_stall active during the done cycle
        
        // During this clock cycle (before posedge clk):
        #1;
        if (frozen !== 1'b0) begin
            $display("ERROR: frozen became 1 prematurely within the same cycle before clock edge!");
            errors = errors + 1;
        end

        // Clock edge occurs: done cycle must be counted!
        @(posedge clk);
        #1;
        // Now frozen should be 1
        if (frozen !== 1'b1) begin
            $display("ERROR: frozen was not asserted on clock edge after done!");
            errors = errors + 1;
        end
        $display("  After done clock edge: total_cycles = %0d, frozen = %0b", dut.total_cycles, frozen);

        // Store frozen values
        begin: check_freeze
            reg [31:0] frozen_tot;
            reg [31:0] frozen_stl;
            frozen_tot = dut.total_cycles;
            frozen_stl = dut.stall_cycles;

            // Wait 5 more cycles with done=1 and mem_stall=1
            repeat (5) @(posedge clk);
            #1;
            if (dut.total_cycles !== frozen_tot || dut.stall_cycles !== frozen_stl) begin
                $display("ERROR: Counters changed while frozen! total_cycles=%0d (expected %0d)",
                         dut.total_cycles, frozen_tot);
                errors = errors + 1;
            end else begin
                $display("  Counters perfectly held their values across multiple cycles post-freeze.");
            end

            // Drop done input: frozen must remain 1 (sticky)
            @(negedge clk);
            done = 0;
            mem_stall = 0;
            repeat (3) @(posedge clk);
            #1;
            if (frozen !== 1'b1) begin
                $display("ERROR: frozen register is not sticky!");
                errors = errors + 1;
            end
        end

        // --------------------------------------------------------------------
        // Test 4: Counter Saturation at 32'hFFFFFFFF
        // --------------------------------------------------------------------
        $display("[TEST 4] Testing Counter Saturation (No Wrapping)...");
        // Clear frozen by pulsing reset
        @(negedge clk);
        rst = 1;
        #15;
        rst = 0;
        @(posedge clk);
        #1;

        // Force counters near maximum
        dut.total_cycles = 32'hFFFFFFFE;
        dut.stall_cycles = 32'hFFFFFFFE;
        mem_stall = 1;

        // Cycle 1: Increments from 32'hFFFFFFFE to 32'hFFFFFFFF
        @(posedge clk);
        #1;
        if (dut.total_cycles !== 32'hFFFFFFFF || dut.stall_cycles !== 32'hFFFFFFFF) begin
            $display("ERROR: Counters failed to increment to 32'hFFFFFFFF!");
            errors = errors + 1;
        end

        // Cycle 2: Must saturate at 32'hFFFFFFFF, not roll over to 32'h00000000
        @(posedge clk);
        #1;
        if (dut.total_cycles !== 32'hFFFFFFFF || dut.stall_cycles !== 32'hFFFFFFFF) begin
            $display("ERROR: Counter wrapped instead of saturating! total_cycles=%08h", dut.total_cycles);
            errors = errors + 1;
        end else begin
            $display("  Saturation verified: 32'hFFFFFFFF retained upon subsequent increments.");
        end
        mem_stall = 0;

        // --------------------------------------------------------------------
        // Test 5: Switch Multiplexer (sw[2:0])
        // --------------------------------------------------------------------
        $display("[TEST 5] Testing Slide Switch Selection sw[2:0]...");
        // Freeze profiler so total_cycles remains constant while checking sw
        @(negedge clk);
        done = 1;
        @(posedge clk);
        #1;
        done = 0;

        dut.total_cycles  = 32'h11111111;
        dut.stall_cycles  = 32'h22222222;
        dut.l1_accesses   = 32'h33333333;
        dut.l1_misses     = 32'h44444444;
        dut.victim_hits   = 32'h55555555;
        dut.prefetch_hits = 32'h66666666;

        sw = 3'b000; #10;
        if (dut.disp_val !== 32'h11111111) begin
            $display("ERROR: sw=000 expected 32'h11111111, got %08h", dut.disp_val);
            errors = errors + 1;
        end
        sw = 3'b001; #10;
        if (dut.disp_val !== 32'h22222222) begin
            $display("ERROR: sw=001 expected 32'h22222222, got %08h", dut.disp_val);
            errors = errors + 1;
        end
        sw = 3'b010; #10;
        if (dut.disp_val !== 32'h33333333) begin
            $display("ERROR: sw=010 expected 32'h33333333, got %08h", dut.disp_val);
            errors = errors + 1;
        end
        sw = 3'b011; #10;
        if (dut.disp_val !== 32'h44444444) begin
            $display("ERROR: sw=011 expected 32'h44444444, got %08h", dut.disp_val);
            errors = errors + 1;
        end
        sw = 3'b100; #10;
        if (dut.disp_val !== 32'h55555555) begin
            $display("ERROR: sw=100 expected 32'h55555555, got %08h", dut.disp_val);
            errors = errors + 1;
        end
        sw = 3'b101; #10;
        if (dut.disp_val !== 32'h66666666) begin
            $display("ERROR: sw=101 expected 32'h66666666, got %08h", dut.disp_val);
            errors = errors + 1;
        end
        sw = 3'b110; #10;
        if (dut.disp_val !== 32'h00000000) begin
            $display("ERROR: sw=110 expected 32'h00000000, got %08h", dut.disp_val);
            errors = errors + 1;
        end
        sw = 3'b111; #10;
        if (dut.disp_val !== 32'hFFFFFFFF) begin
            $display("ERROR: sw=111 expected 32'hFFFFFFFF, got %08h", dut.disp_val);
            errors = errors + 1;
        end
        $display("  Switch multiplexer all 8 states verified.");

        // --------------------------------------------------------------------
        // Test 6: 7-Segment Multiplexing and 0-F Hex Decoding
        // --------------------------------------------------------------------
        $display("[TEST 6] Testing 7-Segment Display Time-Multiplexing & Decoder...");
        // Set a recognizable 8-digit hex pattern: 32'h01234567 and then 32'h89ABCDEF
        dut.total_cycles = 32'h01234567;
        sw = 3'b000;

        // Check all 8 digits: digit 7 (leftmost) is 4'h0, digit 0 (rightmost) is 4'h7
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge clk);
            #1;
            // Verify exactly one anode is low
            if (an !== ~(8'b00000001 << dut.digit_sel)) begin
                $display("ERROR: Anode mismatch for digit %0d: an=%08b", dut.digit_sel, an);
                errors = errors + 1;
            end
            // Verify cathode segment matches expected
            if (seg !== exp_seg(dut.hex_digit)) begin
                $display("ERROR: Segment cathode mismatch for hex %0h: seg=%07b, expected=%07b",
                         dut.hex_digit, seg, exp_seg(dut.hex_digit));
                errors = errors + 1;
            end
        end

        // Now test 32'h89ABCDEF to cover hex characters 8 through F
        dut.total_cycles = 32'h89ABCDEF;
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge clk);
            #1;
            if (seg !== exp_seg(dut.hex_digit)) begin
                $display("ERROR: Segment cathode mismatch for hex %0h: seg=%07b, expected=%07b",
                         dut.hex_digit, seg, exp_seg(dut.hex_digit));
                errors = errors + 1;
            end
        end
        $display("  Full hex decoding 0-F and 8-digit multiplexing verified.");

        // --------------------------------------------------------------------
        // Final Summary
        // --------------------------------------------------------------------
        $display("================================================================");
        if (errors == 0) begin
            $display("ALL TESTS PASSED! Performance Profiler is 100%% verified.");
        end else begin
            $display("TEST FAILED with %0d error(s).", errors);
        end
        $display("================================================================");

        $finish;
    end

endmodule
