`timescale 1ns / 1ps

// ============================================================================
// Testbench: tb_l1_cache (L1 + 4-Entry Victim Cache + Configurable Memory)
// Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher
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
    reg vc_en;

    // CPU Interface
    reg                   cpu_req;
    reg                   cpu_we;
    reg  [ADDR_WIDTH-1:0] cpu_addr;
    reg  [DATA_WIDTH-1:0] cpu_wdata;
    reg  [3:0]            cpu_wmask;
    wire [DATA_WIDTH-1:0] cpu_rdata;
    wire                  cpu_stall;
    reg                   cache_bypass;

    // Profiling
    wire l1_access;
    wire l1_hit;
    wire l1_miss;
    wire vc_hit_o;

    // Memory Interconnect
    wire                  mem_req;
    wire                  mem_we;
    wire [ADDR_WIDTH-1:0] mem_addr;
    wire [LINE_WIDTH-1:0] mem_wdata;
    wire [LINE_WIDTH-1:0] mem_rdata;
    wire                  mem_ack;

    // Victim Cache Interconnect
    wire [ADDR_WIDTH-1:0] victim_lookup_addr;
    wire                  victim_hit;
    wire [LINE_WIDTH-1:0] victim_hit_data;
    wire                  victim_evict_valid;
    wire                  victim_swap_valid;
    wire [ADDR_WIDTH-1:0] victim_evict_addr;
    wire [LINE_WIDTH-1:0] victim_evict_data;

    // Test & Profiler tracking
    integer pass_count = 0;
    integer fail_count = 0;
    integer cnt_access = 0;
    integer cnt_l1_hit = 0;
    integer cnt_l1_miss= 0;
    integer cnt_vc_hit = 0;

    // ------------------------------------------------------------------------
    // 1. Instantiate L1 Cache Controller
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
        .cache_bypass      (cache_bypass),
        .l1_access         (l1_access),
        .l1_hit            (l1_hit),
        .l1_miss           (l1_miss),
        .vc_hit_o          (vc_hit_o),
        .mem_req           (mem_req),
        .mem_we            (mem_we),
        .mem_addr          (mem_addr),
        .mem_wdata         (mem_wdata),
        .mem_rdata         (mem_rdata),
        .mem_ack           (mem_ack),
        .victim_lookup_addr(victim_lookup_addr),
        .victim_hit        (victim_hit),
        .victim_hit_data   (victim_hit_data),
        .victim_evict_valid(victim_evict_valid),
        .victim_swap_valid (victim_swap_valid),
        .victim_evict_addr (victim_evict_addr),
        .victim_evict_data (victim_evict_data),
        .prefetch_snoop_valid(),
        .prefetch_snoop_addr(),
        .prefetch_snoop_miss(),
        .prefetch_req      (1'b0),
        .prefetch_addr     (32'h0),
        .prefetch_data     (128'h0),
        .prefetch_ack      ()
    );

    // ------------------------------------------------------------------------
    // 2. Instantiate 4-Entry Fully-Associative Victim Cache
    // ------------------------------------------------------------------------
    victim_cache #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .BLOCK_WORDS(BLOCK_WORDS),
        .BLOCK_BITS (4),
        .NUM_ENTRIES(4)
    ) vc_inst (
        .clk        (clk),
        .rst        (rst),
        .vc_en      (vc_en),
        .lookup_addr(victim_lookup_addr),
        .vc_hit     (victim_hit),
        .vc_hit_data(victim_hit_data),
        .evict_valid(victim_evict_valid),
        .swap_valid (victim_swap_valid),
        .evict_addr (victim_evict_addr),
        .evict_data (victim_evict_data)
    );

    // ------------------------------------------------------------------------
    // 3. Instantiate Configurable Latency Main Memory Model
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

    // Monitor Hardware Performance Counters
    always @(posedge clk) begin
        if (rst) begin
            cnt_access  <= 0;
            cnt_l1_hit  <= 0;
            cnt_l1_miss <= 0;
            cnt_vc_hit  <= 0;
        end else begin
            if (l1_access) cnt_access  <= cnt_access + 1;
            if (l1_hit)    cnt_l1_hit  <= cnt_l1_hit + 1;
            if (l1_miss)   cnt_l1_miss <= cnt_l1_miss + 1;
            if (vc_hit_o)  cnt_vc_hit  <= cnt_vc_hit + 1;
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
        $display("  L1 CACHE + 4-ENTRY VICTIM CACHE VERIFICATION SUITE (Group 14)");
        $display("==================================================================");

        clk          = 0;
        rst          = 1;
        vc_en        = 1;
        cache_bypass = 0;
        cpu_req      = 0;
        cpu_we      = 0;
        cpu_addr    = 0;
        cpu_wdata   = 0;
        cpu_wmask   = 0;
        latency_sel = 2'b01; // N = 10 cycles

        #20 rst = 0;
        @(posedge clk);

        // --------------------------------------------------------------------
        // Test 1: Cold Miss & Spatial Locality Hits
        // --------------------------------------------------------------------
        $display("\n--- TEST 1: Cold Read Miss (12 Stalls) & Spatial Locality Hits (0 Stalls) ---");
        cpu_read(32'h0000_0000, 32'hCAFE_0000, 12);
        cpu_read(32'h0000_0004, 32'hCAFE_0001, 0);
        cpu_read(32'h0000_0008, 32'hCAFE_0002, 0);
        cpu_read(32'h0000_000C, 32'hCAFE_0003, 0);

        // --------------------------------------------------------------------
        // Test 2: Write Hits Across All Byte/Halfword Masks
        // --------------------------------------------------------------------
        $display("\n--- TEST 2: Write Hits Across Words 0..3 & Sub-Word Masks ---");
        cpu_write(32'h0000_0000, 32'hAABB_CCDD, 4'b1111, 0);
        cpu_write(32'h0000_0004, 32'h0000_9900, 4'b0010, 0);
        cpu_write(32'h0000_0004, 32'h0000_0077, 4'b0001, 0);
        cpu_write(32'h0000_0008, 32'h1255_0000, 4'b1100, 0);
        cpu_write(32'h0000_000C, 32'hEE00_BEEF, 4'b1011, 0);
        cpu_read (32'h0000_0000, 32'hAABB_CCDD, 0);
        cpu_read (32'h0000_0004, 32'hCAFE_9977, 0);
        cpu_read (32'h0000_0008, 32'h1255_0002, 0);
        cpu_read (32'h0000_000C, 32'hEEFE_BEEF, 0);

        // --------------------------------------------------------------------
        // Test 3: Dirty Conflict Miss -> Pushes Block 0 (0x0000) to Victim Cache!
        // --------------------------------------------------------------------
        $display("\n--- TEST 3: Dirty Conflict Miss on Set 0 (Pushes 0x0000 to Victim Cache) ---");
        cpu_read(32'h0000_0800, 32'h4444_0800, 24); // Write-back + Allocate = 24 stalls

        // --------------------------------------------------------------------
        // Test 4: Victim Cache HIT & 2-Cycle Hardware Swap!
        // Re-reading 0x0000_0000 (evicted in Test 3) now hits in the Victim Cache!
        // Since 0x0800 in L1 is CLEAN, swap completes in ONLY 2 STALL CYCLES!
        // --------------------------------------------------------------------
        $display("\n--- TEST 4: Victim Cache Hit & 2-Cycle Clean Block Swap ---");
        cpu_read(32'h0000_0000, 32'hAABB_CCDD, 2); // 2 stalls instead of 12!
        cpu_read(32'h0000_0004, 32'hCAFE_9977, 0); // L1 Hit on swapped block
        // And 0x0800 is now in the Victim Cache! Reading 0x0800 also takes 2 stalls:
        cpu_read(32'h0000_0800, 32'h4444_0800, 2);

        // --------------------------------------------------------------------
        // Test 5: Write Hit on L1 + Victim Cache Hit (Dirty L1 + VC Swap = N+4 = 14 Stalls)
        // Modify 0x0800 in L1 (making it DIRTY), then request 0x0000 (which is in VC).
        // L1 writes back 0x0800 (11 cyc) + WB_WAIT (1) + VC_SWAP (1) + IDLE (1) = 14 stalls!
        // --------------------------------------------------------------------
        $display("\n--- TEST 5: Dirty L1 Eviction + Victim Cache Hit (14 Stalls vs 24 Stalls) ---");
        cpu_write(32'h0000_0800, 32'hDEAD_BEEF, 4'b1111, 0); // Mark Set 0 dirty
        cpu_read (32'h0000_0000, 32'hAABB_CCDD, 14);         // Writeback + VC Swap = 14 stalls!

        // --------------------------------------------------------------------
        // Test 6: Sub-Word Write Miss Hitting in Victim Cache (2 Stalls)
        // 0x0800 is in the Victim Cache; Set 0 in L1 (0x0000) is currently CLEAN.
        // Issue a halfword write to 0x0804 -> Hits VC, swaps & merges in 2 stalls!
        // --------------------------------------------------------------------
        $display("\n--- TEST 6: Sub-Word Write Miss Hitting in Victim Cache (2 Stalls) ---");
        cpu_write(32'h0000_0804, 32'h0000_FACE, 4'b0011, 2);
        cpu_read (32'h0000_0800, 32'hDEAD_BEEF, 0);
        cpu_read (32'h0000_0804, 32'h3333_FACE, 0);

        // --------------------------------------------------------------------
        // Test 7: 4-Entry Victim Cache Capacity & True LRU Replacement Verification
        // Use Set 2 (0x0020, 0x0820, 0x1020, 0x1820, 0x2020) to fill L1 + all 4 VC slots:
        // --------------------------------------------------------------------
        $display("\n--- TEST 7: 4-Entry Victim Cache Capacity & True LRU ReplacementOrder ---");
        cpu_read(32'h0000_0020, 32'h4444_0020, 12); // L1: 0020 | VC: []
        cpu_read(32'h0000_0820, 32'h4444_0820, 12); // L1: 0820 | VC: [0020]
        cpu_read(32'h0000_1020, 32'h4444_1020, 12); // L1: 1020 | VC: [0820, 0020]
        cpu_read(32'h0000_1820, 32'h4444_1820, 12); // L1: 1820 | VC: [1020, 0820, 0020]
        cpu_read(32'h0000_2020, 32'h4444_2020, 12); // L1: 2020 | VC: [1820, 1020, 0820, 0020(LRU)]

        // Access 0x0020 (currently the oldest/LRU entry in VC) -> Must HIT VC (2 stalls)
        // After swap: L1 holds 0020, VC holds [2020(MRU), 1820, 1020, 0820(new LRU)]
        cpu_read(32'h0000_0020, 32'h4444_0020, 2);

        // Now fetch a 6th colliding block (0x2820) -> Misses L1 & VC (12 stalls).
        // Evicts 0020 from L1 into VC, kicking out the true LRU entry (0820)!
        cpu_read(32'h0000_2820, 32'h4444_2820, 12);

        // Verify 1020 is STILL in the Victim Cache (2 stalls):
        cpu_read(32'h0000_1020, 32'h4444_1020, 2);
        // Verify 0820 was evicted from the Victim Cache as LRU (must take 12 stalls):
        cpu_read(32'h0000_0820, 32'h4444_0820, 12);

        // --------------------------------------------------------------------
        // Test 8: High DRAM Latency (N=200) vs 2-Cycle Victim Cache Swap
        // --------------------------------------------------------------------
        $display("\n--- TEST 8: N=200 Cycle DRAM Penalty vs 2-Cycle Victim Cache Swap ---");
        latency_sel = 2'b11; // N = 200 cycles
        cpu_read(32'h0000_07F0, 32'h4444_07F0, 202); // Set 127 Cold Miss = 202 stalls
        cpu_read(32'h0000_0FF0, 32'h4444_0FF0, 202); // Set 127 Conflict Miss = 202 stalls (07F0 -> VC)
        cpu_read(32'h0000_07F0, 32'h4444_07F0, 2);   // Set 127 Victim Cache Hit = ONLY 2 STALLS!

        // --------------------------------------------------------------------
        // Test 9: Profiler Invariant Check
        // --------------------------------------------------------------------
        $display("\n--- TEST 9: Hardware Profiler Summary ---");
        $display("[INFO] L1 Accesses: %0d | L1 Hits: %0d | L1 Misses: %0d | Victim Cache Hits: %0d",
                 cnt_access, cnt_l1_hit, cnt_l1_miss, cnt_vc_hit);
        if ((cnt_access === (cnt_l1_hit + cnt_l1_miss)) && (cnt_vc_hit == 7)) begin
            $display("[PASS] Profiler Counters Verified (7 Victim Cache Hits Intercepted)");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Profiler Counter Mismatch!");
            fail_count = fail_count + 1;
        end

        #50;
        $display("\n==================================================================");
        $display("  TOTAL CHECKS PASSED: %0d | FAILED: %0d", pass_count, fail_count);
        if (fail_count == 0)
            $display("  STATUS: L1 + VICTIM CACHE PASSED 100%% OF TESTS!");
        else
            $display("  STATUS: FAILURES DETECTED.");
        $display("==================================================================");
        $finish;
    end

endmodule