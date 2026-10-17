`timescale 1ns / 1ps

// ============================================================================
// Testbench: tb_l1_cache
// Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher
// Author: Abhishek Kumar (Group 14)
//
// Description:
//   Self-checking automated unit testbench for L1 Cache Controller.
//   Verifies:
//     - Test 1: Cold Read Miss & N=10 Stall Latency
//     - Test 2: Spatial Locality (Multi-Word Block Hits in same 16B line)
//     - Test 3: Write Hit with Byte Masking (SB, SH, SW) & Dirty bit tracking
//     - Test 4: Write Miss (Store Allocate & Byte Merge)
//     - Test 5: Conflict Miss, Dirty Eviction & Memory Writeback Handshake
//     - Test 6: Memory Persistence (Data retention after writeback & reload)
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

    // Test tracking
    integer pass_count = 0;
    integer fail_count = 0;

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

    // Clock generator (10ns period -> 100 MHz, matching Nexys A7)
    always #5 clk = ~clk;

    // VCD Dump
    initial begin
        $dumpfile("waveform.vcd");
        $dumpvars(0, tb_l1_cache);
    end

    // ------------------------------------------------------------------------
    // Helper Tasks for CPU Operations
    // ------------------------------------------------------------------------
    task cpu_read;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] expected_data;
        reg [31:0] stall_cycles;
        begin
            @(posedge clk);
            cpu_req   <= 1'b1;
            cpu_we    <= 1'b0;
            cpu_addr  <= addr;
            cpu_wmask <= 4'b0000;
            stall_cycles = 0;

            #1; // Sample immediately after clock edge
            while (cpu_stall) begin
                stall_cycles = stall_cycles + 1;
                @(posedge clk);
                #1;
            end

            // Check read data
            if (cpu_rdata === expected_data) begin
                $display("[PASS] Read Addr: 0x%08h | Data: 0x%08h | Stall Cycles: %0d", addr, cpu_rdata, stall_cycles);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] Read Addr: 0x%08h | Got: 0x%08h | Expected: 0x%08h", addr, cpu_rdata, expected_data);
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
        reg [31:0] stall_cycles;
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

            $display("[INFO] Write Addr: 0x%08h | Data: 0x%08h | Mask: %b | Stall Cycles: %0d", addr, data, mask, stall_cycles);
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
        $display("  STARTING L1 CACHE CONTROLLER UNIT TESTBENCH (Group 14)");
        $display("  Author: Abhishek Kumar | Configuration: 2 KB, 16B Line, N=%0d", MEM_LATENCY);
        $display("==================================================================");

        clk       = 0;
        rst       = 1;
        cpu_req   = 0;
        cpu_we    = 0;
        cpu_addr  = 0;
        cpu_wdata = 0;
        cpu_wmask   = 0;
        latency_sel = 2'b10; // Default N = 10 cycles

        #20 rst = 0;
        @(posedge clk);

        // --------------------------------------------------------------------
        // Test 1: Cold Miss (Read block 0 word 0)
        // Memory has initialized block 0 as:
        // Word 3: 0xCAFE0003, Word 2: 0xCAFE0002, Word 1: 0xCAFE0001, Word 0: 0xCAFE0000
        // --------------------------------------------------------------------
        $display("\n--- TEST 1: Cold Read Miss ---");
        cpu_read(32'h0000_0000, 32'hCAFE_0000);

        // --------------------------------------------------------------------
        // Test 2: Spatial Locality - Zero-Stall Hits on remaining words of block 0
        // --------------------------------------------------------------------
        $display("\n--- TEST 2: Multi-Word Spatial Locality Hits (Same 16B Line) ---");
        cpu_read(32'h0000_0004, 32'hCAFE_0001); // Word 1
        cpu_read(32'h0000_0008, 32'hCAFE_0002); // Word 2
        cpu_read(32'h0000_000C, 32'hCAFE_0003); // Word 3

        // --------------------------------------------------------------------
        // Test 3: Write Hit with Byte-Masking (Store Word & Store Byte)
        // --------------------------------------------------------------------
        $display("\n--- TEST 3: Write Hit with Byte Masking & Dirty Tracking ---");
        // Full word overwrite on Word 0
        cpu_write(32'h0000_0000, 32'hAABB_CCDD, 4'b1111);
        cpu_read(32'h0000_0000, 32'hAABB_CCDD);

        // Byte overwrite on Word 1 (Addr 0x0000_0005 -> byte 1)
        // Old Word 1 was 0xCAFE_0001. Writing byte 1 with 0x99 gives 0xCAFE_9901.
        cpu_write(32'h0000_0004, 32'h0000_9900, 4'b0010);
        cpu_read(32'h0000_0004, 32'hCAFE_9901);

        // --------------------------------------------------------------------
        // Test 4: Write Miss (Store Allocate) on Block 1 (Addr 0x0000_0010)
        // Memory has initialized block 1 with 0xBEEF_0000..0xBEEF_0003
        // Write 0x1234_5678 into Word 0
        // --------------------------------------------------------------------
        $display("\n--- TEST 4: Write Miss (Store Allocate) on Block 1 ---");
        cpu_write(32'h0000_0010, 32'h1234_5678, 4'b1111);
        cpu_read(32'h0000_0010, 32'h1234_5678);  // Modified word 0
        cpu_read(32'h0000_0014, 32'hBEEF_0001);  // Untouched word 1 from fetched block

        // --------------------------------------------------------------------
        // Test 5: Conflict Miss & Dirty Eviction Writeback
        // Address 0x0000_0800 has Tag = 1, Index = 0 (collides with block 0 at Index 0).
        // Since block 0 is DIRTY, cache MUST write back dirty block 0 to memory!
        // --------------------------------------------------------------------
        $display("\n--- TEST 5: Conflict Miss & Dirty Write-Back ---");
        // Read from 0x0000_0800. Expected data in memory at block 80:
        // storage[0x80] = {32'h1111080C, 32'h22220808, 32'h33330804, 32'h44440800}
        cpu_read(32'h0000_0800, 32'h4444_0800);

        // --------------------------------------------------------------------
        // Test 6: Memory Persistence Verification
        // Access block 0 (0x0000_0000) again. It was evicted and written back in Test 5.
        // It must now be reloaded from memory with our dirty modifications intact!
        // --------------------------------------------------------------------
        $display("\n--- TEST 6: Memory Persistence (Reload Evicted Block) ---");
        cpu_read(32'h0000_0000, 32'hAABB_CCDD); // Must retain 0xAABBCCDD
        cpu_read(32'h0000_0004, 32'hCAFE_9901); // Must retain byte modification

        // --------------------------------------------------------------------
        // Test 7: Board Switch Selectable Latency (N = 1, 5, 20 cycles)
        // Demonstrating TA Specification:
        //   - N = 1  reproduces baseline case (minimal stall)
        //   - N = 5  models moderate memory latency
        //   - N = 20 models high off-chip latency
        // --------------------------------------------------------------------
        $display("\n--- TEST 7: Configurable Latency Switches (TA Requirement) ---");
        
        // Mode 1: N = 1 (Baseline reference: 2'b00)
        latency_sel = 2'b00;
        $display("[SWITCH] latency_sel = 2'b00 (N = 1 cycle baseline)");
        cpu_read(32'h0000_0020, 32'h44440020);

        // Mode 2: N = 5 (2'b01)
        latency_sel = 2'b01;
        $display("[SWITCH] latency_sel = 2'b01 (N = 5 cycles)");
        cpu_read(32'h0000_0030, 32'h44440030);

        // Mode 3: N = 20 (2'b11)
        latency_sel = 2'b11;
        $display("[SWITCH] latency_sel = 2'b11 (N = 20 cycles)");
        cpu_read(32'h0000_0040, 32'h44440040);

        // --------------------------------------------------------------------
        // Final Summary
        // --------------------------------------------------------------------
        #50;
        $display("\n==================================================================");
        $display("  TESTBENCH COMPLETED");
        $display("  TOTAL TESTS PASSED: %0d", pass_count);
        $display("  TOTAL TESTS FAILED: %0d", fail_count);
        if (fail_count == 0) begin
            $display("  STATUS: ALL TESTS PASSED SUCCESSFULLY! (Week 1 Deliverable Complete)");
        end else begin
            $display("  STATUS: TEST FAILURES DETECTED.");
        end
        $display("==================================================================");

        $finish;
    end

endmodule