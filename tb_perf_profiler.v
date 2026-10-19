`timescale 1ns / 1ps

// ============================================================================
// Testbench: tb_perf_profiler
// Module Under Test: perf_profiler
// Description:
//   Self-checking verification testbench for perf_profiler.v.
//   Includes a parallel behavioral reference model, 100000-cycle watchdog,
//   and checks for tests T1 through T11.
// ============================================================================

module tb_perf_profiler;

    // Fast refresh counter parameter: 4 bits -> 16 cycles per refresh frame
    localparam REFRESH_BITS = 4;

    // ------------------------------------------------------------------------
    // DUT Signals
    // ------------------------------------------------------------------------
    reg        clk;
    reg        rst;           // Asynchronous active-high reset (matches perf_profiler.v)
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

    // ------------------------------------------------------------------------
    // Behavioral Reference Model (mirrors architectural specification)
    // ------------------------------------------------------------------------
    reg [31:0] ref_total_cycles;
    reg [31:0] ref_stall_cycles;
    reg [31:0] ref_l1_accesses;
    reg [31:0] ref_l1_misses;
    reg [31:0] ref_victim_hits;
    reg [31:0] ref_prefetch_hits;
    reg        ref_frozen;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ref_frozen        <= 1'b0;
            ref_total_cycles  <= 32'd0;
            ref_stall_cycles  <= 32'd0;
            ref_l1_accesses   <= 32'd0;
            ref_l1_misses     <= 32'd0;
            ref_victim_hits   <= 32'd0;
            ref_prefetch_hits <= 32'd0;
        end else begin
            if (!ref_frozen) begin
                if (done) begin
                    ref_frozen <= 1'b1;
                end

                if (ref_total_cycles != 32'hFFFFFFFF)
                    ref_total_cycles <= ref_total_cycles + 1'b1;

                if (mem_stall && (ref_stall_cycles != 32'hFFFFFFFF))
                    ref_stall_cycles <= ref_stall_cycles + 1'b1;

                if (l1_access && (ref_l1_accesses != 32'hFFFFFFFF))
                    ref_l1_accesses <= ref_l1_accesses + 1'b1;

                if (l1_miss && (ref_l1_misses != 32'hFFFFFFFF))
                    ref_l1_misses <= ref_l1_misses + 1'b1;

                if (victim_hit && (ref_victim_hits != 32'hFFFFFFFF))
                    ref_victim_hits <= ref_victim_hits + 1'b1;

                if (prefetch_hit && (ref_prefetch_hits != 32'hFFFFFFFF))
                    ref_prefetch_hits <= ref_prefetch_hits + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // DUT Instantiation
    // ------------------------------------------------------------------------
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

    // ------------------------------------------------------------------------
    // 10 ns Clock Generation (100 MHz)
    // ------------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------------------
    // 100,000-Cycle Watchdog
    // ------------------------------------------------------------------------
    initial begin
        repeat (100000) @(posedge clk);
        $display("FAIL: Watchdog timeout after 100000 cycles!");
        errors = errors + 1;
        $display("%0d TESTS FAILED", errors);
        $finish;
    end

    // ------------------------------------------------------------------------
    // Check Task
    // ------------------------------------------------------------------------
    task check;
        input [8*64:1] name;
        input [31:0]   got;
        input [31:0]   expected;
        begin
            if (got === expected) begin
                $display("PASS: %0s (got=0x%08h)", name, got);
            end else begin
                $display("FAIL: %0s: got 0x%08h (%0d), expected 0x%08h (%0d)",
                         name, got, got, expected, expected);
                errors = errors + 1;
            end
        end
    endtask

    // Check DUT counters against reference model
    task check_counters_against_ref;
        input [8*48:1] tag;
        begin
            check({tag, " total_cycles"},  dut.total_cycles,  ref_total_cycles);
            check({tag, " stall_cycles"},  dut.stall_cycles,  ref_stall_cycles);
            check({tag, " l1_accesses"},   dut.l1_accesses,   ref_l1_accesses);
            check({tag, " l1_misses"},     dut.l1_misses,     ref_l1_misses);
            check({tag, " victim_hits"},   dut.victim_hits,   ref_victim_hits);
            check({tag, " prefetch_hits"}, dut.prefetch_hits, ref_prefetch_hits);
            check({tag, " frozen"},        {31'd0, dut.frozen}, {31'd0, ref_frozen});
        end
    endtask

    // ------------------------------------------------------------------------
    // Segment Lookup and Reverse Lookup Functions
    // Active-low: {CG, CF, CE, CD, CC, CB, CA}
    // ------------------------------------------------------------------------
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

    function [3:0] seg_to_hex;
        input [6:0] s;
        case (s)
            7'b1000000: seg_to_hex = 4'h0;
            7'b1111001: seg_to_hex = 4'h1;
            7'b0100100: seg_to_hex = 4'h2;
            7'b0110000: seg_to_hex = 4'h3;
            7'b0011001: seg_to_hex = 4'h4;
            7'b0010010: seg_to_hex = 4'h5;
            7'b0000010: seg_to_hex = 4'h6;
            7'b1111000: seg_to_hex = 4'h7;
            7'b0000000: seg_to_hex = 4'h8;
            7'b0010000: seg_to_hex = 4'h9;
            7'b0001000: seg_to_hex = 4'hA;
            7'b0000011: seg_to_hex = 4'hB;
            7'b1000110: seg_to_hex = 4'hC;
            7'b0100001: seg_to_hex = 4'hD;
            7'b0000110: seg_to_hex = 4'hE;
            7'b0001110: seg_to_hex = 4'hF;
            default:    seg_to_hex = 4'h0;
        endcase
    endfunction

    // Task to scan one full refresh frame (16 cycles) and reconstruct the 32-bit display value
    task scan_and_rebuild_display;
        output [31:0] rebuilt;
        reg [3:0] nibbles [0:7];
        integer step;
        integer d;
        begin
            rebuilt = 32'd0;
            for (step = 0; step < 16; step = step + 1) begin
                @(posedge clk);
                #1;
                for (d = 0; d < 8; d = d + 1) begin
                    if (an[d] == 1'b0) begin
                        nibbles[d] = seg_to_hex(seg);
                    end
                end
            end
            rebuilt = {nibbles[7], nibbles[6], nibbles[5], nibbles[4],
                       nibbles[3], nibbles[2], nibbles[1], nibbles[0]};
        end
    endtask

    // ------------------------------------------------------------------------
    // Main Test Sequence
    // ------------------------------------------------------------------------
    integer k;
    integer seed_val;
    reg [31:0] pre_done_cycles;
    reg [31:0] snap_total, snap_stall, snap_access, snap_miss, snap_victim, snap_prefetch;
    reg [31:0] rebuilt_disp;
    integer sw_val;
    integer t10_errors;
    integer zeros;
    integer d_idx;

    initial begin
        // Waveform dump
        $dumpfile("perf_profiler.vcd");
        $dumpvars(0, tb_perf_profiler);

        // Signal initialization
        rst          = 0;
        done         = 0;
        mem_stall    = 0;
        l1_access    = 0;
        l1_hit       = 0;
        l1_miss      = 0;
        victim_hit   = 0;
        prefetch_hit = 0;
        sw           = 3'b000;
        seed_val     = 32'hDEAD_BEEF;

        $display("================================================================");
        $display("Starting Self-Checking Verification for perf_profiler.v");
        $display("================================================================");

        // --------------------------------------------------------------------
        // T1: Reset: all six counters 0, frozen 0
        // --------------------------------------------------------------------
        $display("\n--- [T1] Reset Verification ---");
        @(negedge clk);
        rst = 1;
        #15;
        check("T1 Reset total_cycles == 0",  dut.total_cycles,  32'd0);
        check("T1 Reset stall_cycles == 0",  dut.stall_cycles,  32'd0);
        check("T1 Reset l1_accesses == 0",   dut.l1_accesses,   32'd0);
        check("T1 Reset l1_misses == 0",     dut.l1_misses,     32'd0);
        check("T1 Reset victim_hits == 0",   dut.victim_hits,   32'd0);
        check("T1 Reset prefetch_hits == 0", dut.prefetch_hits, 32'd0);
        check("T1 Reset frozen == 0",        {31'd0, dut.frozen}, 32'd0);
        check("T1 Reset dp == 1",            {31'd0, dp}, 32'd1);
        check_counters_against_ref("T1");
        @(negedge clk);
        rst = 0;

        // --------------------------------------------------------------------
        // T2: Pure cycles: 50 idle cycles -> total_cycles == 50, others 0
        // --------------------------------------------------------------------
        $display("\n--- [T2] Pure Cycles (50 idle cycles) ---");
        repeat (50) @(posedge clk);
        #1;
        check("T2 total_cycles == 50", dut.total_cycles, 32'd50);
        check("T2 stall_cycles == 0",  dut.stall_cycles, 32'd0);
        check("T2 l1_accesses == 0",   dut.l1_accesses, 32'd0);
        check("T2 l1_misses == 0",     dut.l1_misses, 32'd0);
        check("T2 victim_hits == 0",   dut.victim_hits, 32'd0);
        check("T2 prefetch_hits == 0", dut.prefetch_hits, 32'd0);
        check("T2 frozen == 0",        {31'd0, dut.frozen}, 32'd0);
        check_counters_against_ref("T2");

        // --------------------------------------------------------------------
        // T3: Directed events: 10 l1_access pulses, 3 of them with l1_miss,
        //     7 cycles of mem_stall, 2 victim_hit pulses, 1 prefetch_hit pulse
        // --------------------------------------------------------------------
        $display("\n--- [T3] Directed Events ---");
        // Reset counters and reference model to start cleanly
        @(negedge clk);
        rst = 1;
        @(negedge clk);
        rst = 0;

        // 3 cycles: l1_access with l1_miss and mem_stall
        l1_access = 1;
        l1_miss   = 1;
        mem_stall = 1;
        @(posedge clk);

        repeat (2) begin
            @(negedge clk);
            l1_access = 1;
            l1_miss   = 1;
            mem_stall = 1;
            @(posedge clk);
        end

        // 4 cycles: mem_stall alone (total stall = 3 + 4 = 7)
        repeat (4) begin
            @(negedge clk);
            l1_access = 0;
            l1_miss   = 0;
            mem_stall = 1;
            @(posedge clk);
        end

        // 7 cycles: l1_access without miss (total access = 3 + 7 = 10, miss = 3)
        repeat (7) begin
            @(negedge clk);
            mem_stall = 0;
            l1_access = 1;
            l1_miss   = 0;
            @(posedge clk);
        end

        // 2 cycles: victim_hit pulses
        repeat (2) begin
            @(negedge clk);
            l1_access  = 0;
            victim_hit = 1;
            @(posedge clk);
        end

        // 1 cycle: prefetch_hit pulse
        @(negedge clk);
        victim_hit   = 0;
        prefetch_hit = 1;
        @(posedge clk);

        // Clear all event inputs
        @(negedge clk);
        prefetch_hit = 0;
        #1;

        // Total cycles: 3 + 4 + 7 + 2 + 1 = 17 cycles
        check("T3 l1_accesses == 10", dut.l1_accesses, 32'd10);
        check("T3 l1_misses == 3",    dut.l1_misses, 32'd3);
        check("T3 stall_cycles == 7",  dut.stall_cycles, 32'd7);
        check("T3 victim_hits == 2",   dut.victim_hits, 32'd2);
        check("T3 prefetch_hits == 1", dut.prefetch_hits, 32'd1);
        check("T3 total_cycles == 17", dut.total_cycles, 32'd17);
        check_counters_against_ref("T3");

        // --------------------------------------------------------------------
        // T4: Random traffic: 2000 cycles, random access/miss/stall/victim/prefetch
        //     (miss only when access; fixed $random seed)
        // --------------------------------------------------------------------
        $display("\n--- [T4] Random Traffic (2000 cycles) ---");
        @(negedge clk);
        rst = 1;
        @(negedge clk);
        rst = 0;

        for (k = 0; k < 2000; k = k + 1) begin
            if (k > 0) @(negedge clk);
            l1_access    = (($random(seed_val) & 32'h3) == 0); // 25% access rate
            l1_miss      = l1_access && (($random(seed_val) & 32'h1) == 0); // miss only when access
            mem_stall    = (($random(seed_val) & 32'h7) == 0); // 12.5% stall rate
            victim_hit   = (($random(seed_val) & 32'hF) == 0); // 6.25% victim rate
            prefetch_hit = (($random(seed_val) & 32'hF) == 0); // 6.25% prefetch rate
            @(posedge clk);
        end

        @(negedge clk);
        l1_access    = 0;
        l1_miss      = 0;
        mem_stall    = 0;
        victim_hit   = 0;
        prefetch_hit = 0;
        #1;
        check_counters_against_ref("T4 Random Traffic");

        // --------------------------------------------------------------------
        // T5: Done-freeze: assert done for 1 cycle, then keep driving events
        //     for 100 more cycles -> frozen==1, all counters unchanged;
        //     done deasserted does NOT unfreeze (sticky).
        //     Check the documented off-by-one for total_cycles.
        // --------------------------------------------------------------------
        $display("\n--- [T5] Done-Freeze & Off-by-One Verification ---");
        @(negedge clk);
        pre_done_cycles = dut.total_cycles;
        done      = 1;
        mem_stall = 1;
        l1_access = 1;

        // Verify frozen is still 0 during this cycle before posedge clk
        #1;
        check("T5 frozen before clock edge", {31'd0, dut.frozen}, 32'd0);

        // Clock edge occurs: done cycle is counted, frozen transitions to 1
        @(posedge clk);
        #1;
        check("T5 frozen after clock edge", {31'd0, dut.frozen}, 32'd1);
        check("T5 off-by-one: total_cycles captures done cycle", dut.total_cycles, pre_done_cycles + 1);
        check_counters_against_ref("T5 At Freeze");

        // Snapshot counters at moment of freeze
        snap_total    = dut.total_cycles;
        snap_stall    = dut.stall_cycles;
        snap_access   = dut.l1_accesses;
        snap_miss     = dut.l1_misses;
        snap_victim   = dut.victim_hits;
        snap_prefetch = dut.prefetch_hits;

        // Deassert done (verify sticky behavior) and drive continuous events for 100 cycles
        @(negedge clk);
        done = 0;

        for (k = 0; k < 100; k = k + 1) begin
            @(negedge clk);
            mem_stall    = 1;
            l1_access    = 1;
            l1_miss      = 1;
            victim_hit   = 1;
            prefetch_hit = 1;
            @(posedge clk);
        end

        @(negedge clk);
        mem_stall    = 0;
        l1_access    = 0;
        l1_miss      = 0;
        victim_hit   = 0;
        prefetch_hit = 0;
        #1;

        check("T5 frozen sticky after 100 cycles", {31'd0, dut.frozen}, 32'd1);
        check("T5 total_cycles held", dut.total_cycles, snap_total);
        check("T5 stall_cycles held", dut.stall_cycles, snap_stall);
        check("T5 l1_accesses held", dut.l1_accesses, snap_access);
        check("T5 l1_misses held", dut.l1_misses, snap_miss);
        check("T5 victim_hits held", dut.victim_hits, snap_victim);
        check("T5 prefetch_hits held", dut.prefetch_hits, snap_prefetch);
        check_counters_against_ref("T5 Post-Freeze");

        // --------------------------------------------------------------------
        // T6: Reset after freeze: counters 0, frozen 0, counting resumes
        // --------------------------------------------------------------------
        $display("\n--- [T6] Reset After Freeze & Counting Resumes ---");
        @(negedge clk);
        rst = 1;
        #15;
        check("T6 reset total_cycles == 0",  dut.total_cycles,  32'd0);
        check("T6 reset stall_cycles == 0",  dut.stall_cycles,  32'd0);
        check("T6 reset l1_accesses == 0",   dut.l1_accesses,   32'd0);
        check("T6 reset l1_misses == 0",     dut.l1_misses,     32'd0);
        check("T6 reset victim_hits == 0",   dut.victim_hits,   32'd0);
        check("T6 reset prefetch_hits == 0", dut.prefetch_hits, 32'd0);
        check("T6 reset frozen == 0",        {31'd0, dut.frozen}, 32'd0);
        check_counters_against_ref("T6 In-Reset");

        @(negedge clk);
        rst = 0;

        // Run 20 cycles: verify counting resumes
        repeat (20) @(posedge clk);
        #1;
        check("T6 counting resumes: total_cycles == 20", dut.total_cycles, 32'd20);
        check("T6 frozen remains 0", {31'd0, dut.frozen}, 32'd0);
        check_counters_against_ref("T6 Post-Resume");

        // --------------------------------------------------------------------
        // T7: Saturation: force dut.total_cycles to 32'hFFFFFFF0,
        //     run 40 cycles -> stays 32'hFFFFFFFF
        // --------------------------------------------------------------------
        $display("\n--- [T7] Counter Saturation (No Wrapping) ---");
        $deposit(dut.total_cycles, 32'hFFFFFFF0);
        ref_total_cycles = 32'hFFFFFFF0;

        repeat (40) @(posedge clk);
        #1;
        check("T7 total_cycles saturated at 32'hFFFFFFFF", dut.total_cycles, 32'hFFFFFFFF);
        check_counters_against_ref("T7 Saturation");

        // --------------------------------------------------------------------
        // T8: Switch mux: preload distinct values via events, freeze,
        //     then for sw=0..7 scan all 8 anodes over one refresh frame,
        //     decode seg back to hex, rebuild 32-bit shown value, and check
        // --------------------------------------------------------------------
        $display("\n--- [T8] Switch Multiplexer & Frame Reconstruction ---");
        @(negedge clk);
        rst = 1;
        @(negedge clk);
        rst = 0;

        // Preload distinct counts via events:
        // Cycle 1: stall, access, miss, victim, prefetch
        mem_stall = 1; l1_access = 1; l1_miss = 1; victim_hit = 1; prefetch_hit = 1;
        @(posedge clk);

        // Cycle 2: access, miss, victim, prefetch
        @(negedge clk);
        mem_stall = 0; l1_access = 1; l1_miss = 1; victim_hit = 1; prefetch_hit = 1;
        @(posedge clk);

        // Cycle 3: access, miss, victim, prefetch
        @(negedge clk);
        l1_access = 1; l1_miss = 1; victim_hit = 1; prefetch_hit = 1;
        @(posedge clk);

        // Cycle 4: access, victim, prefetch
        @(negedge clk);
        l1_access = 1; l1_miss = 0; victim_hit = 1; prefetch_hit = 1;
        @(posedge clk);

        // Cycle 5: victim, prefetch
        @(negedge clk);
        l1_access = 0; victim_hit = 1; prefetch_hit = 1;
        @(posedge clk);

        // Cycle 6: prefetch
        @(negedge clk);
        victim_hit = 0; prefetch_hit = 1;
        @(posedge clk);

        // Cycle 7: Idle
        @(negedge clk);
        prefetch_hit = 0;
        @(posedge clk);

        // Cycle 8: done = 1 (freezes profiler at cycle 8)
        @(negedge clk);
        done = 1;
        @(posedge clk);
        #1;
        done = 0;

        // Resulting distinct values:
        // total_cycles  = 8
        // stall_cycles  = 1
        // l1_accesses   = 4
        // l1_misses     = 3
        // victim_hits   = 5
        // prefetch_hits = 6
        check("T8 distinct counts: total_cycles == 8", dut.total_cycles, 32'd8);
        check("T8 distinct counts: stall_cycles == 1", dut.stall_cycles, 32'd1);
        check("T8 distinct counts: l1_accesses == 4",  dut.l1_accesses, 32'd4);
        check("T8 distinct counts: l1_misses == 3",    dut.l1_misses, 32'd3);
        check("T8 distinct counts: victim_hits == 5",  dut.victim_hits, 32'd5);
        check("T8 distinct counts: prefetch_hits == 6",dut.prefetch_hits, 32'd6);
        check("T8 frozen == 1", {31'd0, dut.frozen}, 32'd1);

        // For sw=0..7, scan all 8 anodes over one refresh frame, decode seg, rebuild
        for (sw_val = 0; sw_val < 8; sw_val = sw_val + 1) begin
            sw = sw_val[2:0];
            scan_and_rebuild_display(rebuilt_disp);
            case (sw_val)
                0: check("T8 sw=000 routes total_cycles",  rebuilt_disp, dut.total_cycles);
                1: check("T8 sw=001 routes stall_cycles",  rebuilt_disp, dut.stall_cycles);
                2: check("T8 sw=010 routes l1_accesses",   rebuilt_disp, dut.l1_accesses);
                3: check("T8 sw=011 routes l1_misses",     rebuilt_disp, dut.l1_misses);
                4: check("T8 sw=100 routes victim_hits",   rebuilt_disp, dut.victim_hits);
                5: check("T8 sw=101 routes prefetch_hits", rebuilt_disp, dut.prefetch_hits);
                6: check("T8 sw=110 routes 0x00000000",    rebuilt_disp, 32'h00000000);
                7: check("T8 sw=111 routes 0xFFFFFFFF",    rebuilt_disp, 32'hFFFFFFFF);
            endcase
        end

        // --------------------------------------------------------------------
        // T9: Segment table: show 32'h01234567 then 32'h89ABCDEF,
        //     check all 16 hex digit encodings are exact (active-low)
        // --------------------------------------------------------------------
        $display("\n--- [T9] 7-Segment Hex Decoder Table Verification (0-F) ---");
        sw = 3'b000; // Selects total_cycles
        $deposit(dut.total_cycles, 32'h01234567);

        // Scan 16 cycles: check hex digits 0 to 7
        for (k = 0; k < 16; k = k + 1) begin
            @(posedge clk);
            #1;
            for (d_idx = 0; d_idx < 8; d_idx = d_idx + 1) begin
                if (an[d_idx] == 1'b0) begin
                    // Digit 7 = 0, Digit 6 = 1, ..., Digit 0 = 7 -> expected = 7 - d_idx
                    if (seg !== exp_seg(7 - d_idx)) begin
                        $display("FAIL: T9 digit %0d hex %0h seg mismatch: got 7'b%07b, expected 7'b%07b",
                                 d_idx, (7 - d_idx), seg, exp_seg(7 - d_idx));
                        errors = errors + 1;
                    end
                end
            end
        end

        // Now test upper digits 8 to F
        $deposit(dut.total_cycles, 32'h89ABCDEF);

        // Scan 16 cycles: check hex digits 8 to F
        for (k = 0; k < 16; k = k + 1) begin
            @(posedge clk);
            #1;
            for (d_idx = 0; d_idx < 8; d_idx = d_idx + 1) begin
                if (an[d_idx] == 1'b0) begin
                    // Digit 7 = 8, Digit 6 = 9, ..., Digit 0 = F -> expected = 15 - d_idx
                    if (seg !== exp_seg(15 - d_idx)) begin
                        $display("FAIL: T9 digit %0d hex %0h seg mismatch: got 7'b%07b, expected 7'b%07b",
                                 d_idx, (15 - d_idx), seg, exp_seg(15 - d_idx));
                        errors = errors + 1;
                    end
                end
            end
        end
        $display("PASS: T9 all 16 hex digit segment encodings 0-F validated");

        // --------------------------------------------------------------------
        // T10: an[] is always one-hot-low (exactly one 0 bit) at every clock
        //      in a 2-frame window
        // --------------------------------------------------------------------
        $display("\n--- [T10] Anode One-Hot-Low Verification Across 2 Frames ---");
        t10_errors = 0;
        // 2 frames = 32 clock cycles (with REFRESH_BITS = 4)
        for (k = 0; k < 32; k = k + 1) begin
            @(posedge clk);
            #1;
            zeros = (!an[0]) + (!an[1]) + (!an[2]) + (!an[3]) +
                    (!an[4]) + (!an[5]) + (!an[6]) + (!an[7]);
            if (zeros != 1) begin
                $display("FAIL: T10 an not one-hot-low at cycle %0d: an=8'b%08b (zeros=%0d)",
                         k, an, zeros);
                t10_errors = t10_errors + 1;
            end
        end
        check("T10 an[] strictly one-hot-low over 32 cycles", t10_errors, 32'd0);

        // --------------------------------------------------------------------
        // T11: Tie-off check: with victim_hit and prefetch_hit tied to 0
        //      for 1000 random cycles, counters 4 and 5 stay 0
        // --------------------------------------------------------------------
        $display("\n--- [T11] Tie-off Check for victim_hit & prefetch_hit ---");
        @(negedge clk);
        rst = 1;
        @(negedge clk);
        rst = 0;

        victim_hit   = 1'b0;
        prefetch_hit = 1'b0;

        for (k = 0; k < 1000; k = k + 1) begin
            if (k > 0) @(negedge clk);
            l1_access = (($random(seed_val) & 32'h3) == 0);
            l1_miss   = l1_access && (($random(seed_val) & 32'h1) == 0);
            mem_stall = (($random(seed_val) & 32'h7) == 0);
            victim_hit   = 1'b0;
            prefetch_hit = 1'b0;
            @(posedge clk);
        end

        @(negedge clk);
        l1_access = 0;
        l1_miss   = 0;
        mem_stall = 0;
        #1;
        check("T11 victim_hits remains 0",   dut.victim_hits,   32'd0);
        check("T11 prefetch_hits remains 0", dut.prefetch_hits, 32'd0);
        check_counters_against_ref("T11");

        // --------------------------------------------------------------------
        // Final Status Reporting
        // --------------------------------------------------------------------
        $display("================================================================");
        if (errors == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("%0d TESTS FAILED", errors);
        end
        $display("================================================================");

        $finish;
    end

endmodule
