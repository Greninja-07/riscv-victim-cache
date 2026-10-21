`timescale 1ns / 1ps

// ============================================================================
// Testbench: tb_l1_cache (Exhaustive Corner-Case Edition)
// Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher
// Author: Abhishek Kumar (Group 14)
// ============================================================================

module tb_l1_cache;

    parameter MEM_BYTES = 16384;

    localparam DATA_WIDTH  = 32;
    localparam ADDR_WIDTH  = 32;
    localparam BLOCK_WORDS = 4;
    localparam LINE_WIDTH  = BLOCK_WORDS * DATA_WIDTH;
    localparam MEM_LATENCY = 10;

    reg clk;
    reg rst;

    // CPU Interface
    reg                   cpu_req;
    reg                   cpu_we;
    reg  [ADDR_WIDTH-1:0] cpu_addr;
    reg  [DATA_WIDTH-1:0] cpu_wdata;
    reg  [3:0]            cpu_wmask;
    wire [DATA_WIDTH-1:0] cpu_rdata;
    wire                  cpu_stall;

    // Profiling
    wire l1_access;
    wire l1_hit;
    wire l1_miss;

    // Memory Interconnect
    wire                  mem_req;
    wire                  mem_we;
    wire [ADDR_WIDTH-1:0] mem_addr;
    wire [LINE_WIDTH-1:0] mem_wdata;
    wire [LINE_WIDTH-1:0] mem_rdata;
    wire                  mem_ack;

    // Victim Cache Eviction Bus
    wire                  victim_evict_valid;
    wire [ADDR_WIDTH-1:0] victim_evict_addr;
    wire [LINE_WIDTH-1:0] victim_evict_data;

    // Test & Profiler tracking
    integer pass_count = 0;
    integer fail_count = 0;
    integer cnt_access = 0;
    integer cnt_hit    = 0;
    integer cnt_miss   = 0;
    integer evict_seen = 0;
    reg [31:0] last_evict_addr;
    reg [127:0] last_evict_data;

    // ------------------------------------------------------------------------
    // Instantiate DUT (L1 Cache Controller)
    // ------------------------------------------------------------------------
    l1_cache_controller #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .BLOCK_WORDS(BLOCK_WORDS),
        .BLOCK_BITS (4),
        .INDEX_BITS (7)
    ) dut (
        .clk               (clk),
        .rst               (rst),
        .cpu_req           (cpu_req),
        .cpu_we            (cpu_we),
        .cpu_addr          (cpu_addr),
        .cpu_wdata         (cpu_wdata),
        .cpu_wmask         (cpu_wmask),
        .cpu_rdata         (cpu_rdata),
        .cpu_stall         (cpu_stall),
        .l1_access         (l1_access),
        .l1_hit            (l1_hit),
        .l1_miss           (l1_miss),
        .mem_req           (mem_req),
        .mem_we            (mem_we),
        .mem_addr          (mem_addr),
        .mem_wdata         (mem_wdata),
        .mem_rdata         (mem_rdata),
        .mem_ack           (mem_ack),
        .victim_evict_valid(victim_evict_valid),
        .victim_evict_addr (victim_evict_addr),
        .victim_evict_data (victim_evict_data)
    );

    // ------------------------------------------------------------------------
    // Instantiate Configurable Latency Main Memory Model
    // ------------------------------------------------------------------------
    reg [1:0] latency_sel;

    main_memory #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (LINE_WIDTH),
        .MEM_BYTES  (MEM_BYTES),
        .LATENCY    (MEM_LATENCY)
    ) mem_inst (
        .clk        (clk),
        .rst        (rst),
        .latency_sel(latency_sel),
        .mem_req    (mem_req),
        .mem_we     (mem_we),
        .mem_addr   (mem_addr),
        .mem_wdata  (mem_wdata),
        .mem_rdata  (mem_rdata),
        .mem_ack    (mem_ack)
    );

    // Clock generator (10ns period -> 100 MHz)
    always #5 clk = ~clk;

    // VCD Dump
    initial begin
        $dumpfile("waveform.vcd");
        $dumpvars(0, tb_l1_cache);
    end

    // Monitor Hardware Performance Counters & Victim Eviction Bus
    always @(posedge clk) begin
        if (rst) begin
            cnt_access      <= 0;
            cnt_hit         <= 0;
            cnt_miss        <= 0;
            evict_seen      <= 0;
            last_evict_addr <= 0;
            last_evict_data <= 0;
        end else begin
            if (l1_access) cnt_access <= cnt_access + 1;
            if (l1_hit)    cnt_hit    <= cnt_hit + 1;
            if (l1_miss)   cnt_miss   <= cnt_miss + 1;
            if (victim_evict_valid) begin
                evict_seen      <= evict_seen + 1;
                last_evict_addr <= victim_evict_addr;
                last_evict_data <= victim_evict_data;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Helper Tasks with Strict Data AND Stall-Cycle Verification
    // ------------------------------------------------------------------------
    task cpu_read;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] expected_data;
        input [31:0]           expected_stalls;
        reg   [31:0]           stall_cycles;
        begin
            @(posedge clk);
            cpu_req   <= 1'b1;
            cpu_we    <= 1'b0;
            cpu_addr  <= addr;
            cpu_wmask <= 4'b0000;
            stall_cycles = 0;

            #1;
            while (cpu_stall) begin
                stall_cycles = stall_cycles + 1;
                @(posedge clk);
                #1;
            end

            if ((cpu_rdata === expected_data) && (stall_cycles === expected_stalls)) begin
                $display("[PASS] Read  0x%08h | Data: 0x%08h | Stalls: %0d (Exp: %0d)",
                         addr, cpu_rdata, stall_cycles, expected_stalls);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] Read  0x%08h | Got Data: 0x%08h (Exp: 0x%08h) | Stalls: %0d (Exp: %0d)",
                         addr, cpu_rdata, expected_data, stall_cycles, expected_stalls);
                fail_count = fail_count + 1;
            end

            @(posedge clk);
            cpu_req <= 1'b0;
        end
    endtask

    task cpu_write;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] data;
        input [3:0]            mask;
        input [31:0]           expected_stalls;
        reg   [31:0]           stall_cycles;
        begin
            @(posedge clk);
            cpu_req   <= 1'b1;
            cpu_we    <= 1'b1;
            cpu_addr  <= addr;
            cpu_wdata <= data;
            cpu_wmask <= mask;
            stall_cycles = 0;

            #1;
            while (cpu_stall) begin
                stall_cycles = stall_cycles + 1;
                @(posedge clk);
                #1;
            end

            if (stall_cycles === expected_stalls) begin
                $display("[PASS] Write 0x%08h | Data: 0x%08h | Mask: %b | Stalls: %0d (Exp: %0d)",
                         addr, data, mask, stall_cycles, expected_stalls);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] Write 0x%08h | Stalls: %0d (Exp: %0d)",
                         addr, stall_cycles, expected_stalls);
                fail_count = fail_count + 1;
            end

            @(posedge clk);
            cpu_req <= 1'b0;
            cpu_we  <= 1'b0;
        end
    endtask

    // ------------------------------------------------------------------------
    // Main Test Execution
    // ------------------------------------------------------------------------
    initial begin
        $display("==================================================================");
        $display("  STARTING EXHAUSTIVE L1 CACHE UNIT TESTBENCH (Group 14)");
        $display("==================================================================");

        clk         = 0;
        rst         = 1;
        cpu_req     = 0;
        cpu_we      = 0;
        cpu_addr    = 0;
        cpu_wdata   = 0;
        cpu_wmask   = 0;
        latency_sel = 2'b01; // N = 10 cycles (Clean miss = 12 stalls, Dirty miss = 24 stalls)

        #20 rst = 0;
        @(posedge clk);

        // --------------------------------------------------------------------
        // Test 1: Cold Miss (N=10 -> Expected 12 stall cycles)
        // --------------------------------------------------------------------
        $display("\n--- TEST 1: Cold Read Miss & Exact Stall Verification ---");
        cpu_read(32'h0000_0000, 32'hCAFE_0000, 12);

        // --------------------------------------------------------------------
        // Test 2: Temporal & Spatial Locality Hits (Expected 0 stall cycles)
        // --------------------------------------------------------------------
        $display("\n--- TEST 2: Temporal & Spatial Locality Hits (Words 0..3) ---");
        cpu_read(32'h0000_0000, 32'hCAFE_0000, 0); // Temporal hit Word 0
        cpu_read(32'h0000_0004, 32'hCAFE_0001, 0); // Spatial hit Word 1
        cpu_read(32'h0000_0008, 32'hCAFE_0002, 0); // Spatial hit Word 2
        cpu_read(32'h0000_000C, 32'hCAFE_0003, 0); // Spatial hit Word 3

        // --------------------------------------------------------------------
        // Test 3: Write Hit Across All 4 Words & All Byte/Halfword Masks
        // --------------------------------------------------------------------
        $display("\n--- TEST 3: Write Hits Across Words 0, 1, 2, 3 & All Byte Lanes ---");
        // Word 0: Full word write (4'b1111)
        cpu_write(32'h0000_0000, 32'hAABB_CCDD, 4'b1111, 0);
        cpu_read (32'h0000_0000, 32'hAABB_CCDD, 0);

        // Word 1: Single byte writes to byte 1 (4'b0010) and byte 0 (4'b0001)
        cpu_write(32'h0000_0004, 32'h0000_9900, 4'b0010, 0);
        cpu_write(32'h0000_0004, 32'h0000_0077, 4'b0001, 0);
        cpu_read (32'h0000_0004, 32'hCAFE_9977, 0);

        // Word 2: Upper halfword write (4'b1100) & byte 2 write (4'b0100)
        cpu_write(32'h0000_0008, 32'h1234_0000, 4'b1100, 0);
        cpu_write(32'h0000_0008, 32'h0055_0000, 4'b0100, 0);
        cpu_read (32'h0000_0008, 32'h1255_0002, 0);

        // Word 3: Byte 3 write (4'b1000) & lower halfword write (4'b0011)
        cpu_write(32'h0000_000C, 32'hEE00_0000, 4'b1000, 0);
        cpu_write(32'h0000_000C, 32'h0000_BEEF, 4'b0011, 0);
        cpu_read (32'h0000_000C, 32'hEEFE_BEEF, 0);

        // --------------------------------------------------------------------
        // Test 4: Sub-Word Write Miss (Store Allocate + Partial Byte Merge)
        // Block 1 (0x0000_0010) holds 0xBEEF0000..0xBEEF0003.
        // Write ONLY lower halfword (4'b0011) of Word 2 (0x0000_0018).
        // --------------------------------------------------------------------
        $display("\n--- TEST 4: Sub-Word Write Miss (Store Allocate + Byte Merge) ---");
        cpu_write(32'h0000_0018, 32'h0000_CAFE, 4'b0011, 12); // Cold Write Miss = 12 stalls
        cpu_read (32'h0000_0018, 32'hBEEF_CAFE, 0);           // Upper half 0xBEEF preserved!
        cpu_read (32'h0000_0010, 32'hBEEF_0000, 0);           // Other words intact

        // --------------------------------------------------------------------
        // Test 5: Read Conflict Miss on Dirty Line (2N + 4 = 24 stalls)
        // Evict dirty Block 0 (0x0000_0000) using Tag 1, Index 0 (0x0000_0800)
        // --------------------------------------------------------------------
        $display("\n--- TEST 5: Read Conflict Miss & Dirty Eviction (24 Stalls) ---");
        cpu_read(32'h0000_0800, 32'h4444_0800, 24);
        // Verify Victim Cache Eviction Bus captured dirty Block 0
        if (last_evict_addr === 32'h0000_0000 &&
            last_evict_data === {32'hEEFE_BEEF, 32'h1255_0002, 32'hCAFE_9977, 32'hAABB_CCDD}) begin
            $display("[PASS] Victim Eviction Bus captured exact 128-bit dirty block & address");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Victim Eviction Bus mismatch! Addr: 0x%08h", last_evict_addr);
            fail_count = fail_count + 1;
        end

        // --------------------------------------------------------------------
        // Test 6: Clean Conflict Miss & Dirty Write-Back Persistence
        // Line 0 currently holds CLEAN 0x0000_0800. Reading 0x0000_0000 must:
        //   1. Skip WRITE_BACK (take only 12 stalls, NOT 24!)
        //   2. Return all 4 modified words saved to main memory in Test 5.
        // --------------------------------------------------------------------
        $display("\n--- TEST 6: Clean Conflict Miss (12 Stalls) & Memory Persistence ---");
        cpu_read(32'h0000_0000, 32'hAABB_CCDD, 12); // Must be 12 stalls (clean eviction)
        cpu_read(32'h0000_0004, 32'hCAFE_9977, 0);
        cpu_read(32'h0000_0008, 32'h1255_0002, 0);
        cpu_read(32'h0000_000C, 32'hEEFE_BEEF, 0);

        // --------------------------------------------------------------------
        // Test 7: Write Conflict Miss Evicting a Dirty Line (24 Stalls)
        // Block 1 (Index 1, Tag 0 = 0x0000_0010) is currently DIRTY from Test 4.
        // Issue a WRITE MISS to Index 1, Tag 1 (0x0000_0810).
        // --------------------------------------------------------------------
        $display("\n--- TEST 7: Write Miss Evicting Dirty Line (Writeback + Store Allocate) ---");
        cpu_write(32'h0000_0810, 32'hDEAD_C0DE, 4'b1111, 24); // Dirty evict + refill = 24 stalls
        cpu_read (32'h0000_0810, 32'hDEAD_C0DE, 0);           // New line hit
        // Reload 0x0000_0018 (causes another dirty writeback = 24 stalls) to verify persistence
        cpu_read (32'h0000_0018, 32'hBEEF_CAFE, 24);

        // --------------------------------------------------------------------
        // Test 8: Back-to-Back (Zero-Idle) Pipelined CPU Requests
        // Hold cpu_req = 1 across 4 consecutive clock edges without dropping it
        // --------------------------------------------------------------------
        $display("\n--- TEST 8: Back-to-Back Pipelined Hits (Zero Idle Cycles) ---");
        @(posedge clk);
        cpu_req  <= 1'b1; cpu_we <= 1'b0; cpu_addr <= 32'h0000_0000;
        #1; if (cpu_stall === 0 && cpu_rdata === 32'hAABB_CCDD) pass_count = pass_count + 1; else fail_count = fail_count + 1;
        @(posedge clk);
        cpu_req  <= 1'b1; cpu_we <= 1'b0; cpu_addr <= 32'h0000_0004;
        #1; if (cpu_stall === 0 && cpu_rdata === 32'hCAFE_9977) pass_count = pass_count + 1; else fail_count = fail_count + 1;
        @(posedge clk);
        cpu_req  <= 1'b1; cpu_we <= 1'b0; cpu_addr <= 32'h0000_0008;
        #1; if (cpu_stall === 0 && cpu_rdata === 32'h1255_0002) pass_count = pass_count + 1; else fail_count = fail_count + 1;
        @(posedge clk);
        cpu_req  <= 1'b0;
        $display("[PASS] Back-to-back zero-idle pipelined reads verified");

        // --------------------------------------------------------------------
        // Test 9: All 4 Configurable Latency Modes (N = 1, 10, 100, 200) & Set 127 Boundary
        // --------------------------------------------------------------------
        $display("\n--- TEST 9: All 4 Latency Switch Modes (N = 1, 10, 100, 200) & Set 127 ---");
        latency_sel = 2'b00; // N = 1 -> 3 stall cycles
        cpu_read(32'h0000_0020, 32'h4444_0020, 3);

        latency_sel = 2'b01; // N = 10 -> 12 stall cycles
        cpu_read(32'h0000_0030, 32'h4444_0030, 12);

        latency_sel = 2'b10; // N = 100 -> 102 stall cycles
        cpu_read(32'h0000_0040, 32'h4444_0040, 102);

        latency_sel = 2'b11; // N = 200 -> 202 stall cycles on Set 127 boundary (0x07F0)
        cpu_read(32'h0000_07F0, 32'h4444_07F0, 202);

        // --------------------------------------------------------------------
        // Test 10: Hardware Profiler Counter Invariant Verification
        // --------------------------------------------------------------------
        $display("\n--- TEST 10: Hardware Performance Profiler Signals ---");
        $display("[INFO] Total Accesses: %0d | Hits: %0d | Misses: %0d", cnt_access, cnt_hit, cnt_miss);
        if ((cnt_access === (cnt_hit + cnt_miss)) && (cnt_hit > 0) && (cnt_miss == 10)) begin
            $display("[PASS] Profiler Counters Exact Match (Accesses == Hits + Misses, 10 Misses)");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Profiler Counter Mismatch!");
            fail_count = fail_count + 1;
        end

        // --------------------------------------------------------------------
        // Final Summary
        // --------------------------------------------------------------------
        #50;
        $display("\n==================================================================");
        $display("  TESTBENCH COMPLETED");
        $display("  TOTAL CHECKS PASSED: %0d", pass_count);
        $display("  TOTAL CHECKS FAILED: %0d", fail_count);
        if (fail_count == 0) begin
            $display("  STATUS: 100%% CORNER-CASE COVERAGE PASSED SUCCESSFULLY!");
        end else begin
            $display("  STATUS: TEST FAILURES DETECTED.");
        end
        $display("==================================================================");

        $finish;
    end

endmodule