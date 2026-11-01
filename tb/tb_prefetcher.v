`timescale 1ns / 1ps

// ============================================================================
// Testbench: tb_prefetcher
// Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher
// Author: Archit & Team (Group 14)
//
// Description:
//   Self-checking verification testbench for rtl/prefetch/prefetcher.v covering:
//   1. Constant stride +16 detected after expected training accesses
//   2. Constant stride +32 detected
//   3. Constant stride -16 (negative) detected
//   4. Stride change -> retraining
//   5. Zero stride -> ignored (no prefetch)
//   6. Two interleaved PCs with different strides -> both work independently
//   7. PC aliasing (two PCs map same table index, different tags) -> no wrong data
//   8. Prefetch target already in L1 -> no request issued
//   9. Store to buffered line -> invalidates it
//   10. Demand miss during in-flight prefetch: same line -> merge; different line -> no deadlock
//       Tested at N = 1, 10, 100, 200 cycles
//   11. Prefetch buffer hit latency <= 2 cycles
//   12. SW[8]=0 -> zero prefetch activity
// ============================================================================

module tb_prefetcher;

    parameter ADDR_WIDTH = 32;
    parameter DATA_WIDTH = 128;

    reg clk;
    reg rst;

    // Controls
    reg prefetch_en;
    reg cache_bypass;

    // Training snoop
    reg                  is_load;
    reg [ADDR_WIDTH-1:0] load_pc;
    reg [ADDR_WIDTH-1:0] load_addr;
    reg                  load_stall;

    // Store coherence
    reg                  store_valid;
    reg [ADDR_WIDTH-1:0] store_addr;

    // L1 status
    reg                  l1_idle;
    reg                  l1_tag_hit;

    // L1 demand interface
    reg                  l1_mem_req;
    reg                  l1_mem_we;
    reg [ADDR_WIDTH-1:0] l1_mem_addr;
    reg [DATA_WIDTH-1:0] l1_mem_wdata;
    wire [DATA_WIDTH-1:0] l1_mem_rdata;
    wire                 l1_mem_ack;

    // Main memory bus
    wire                 mem_req;
    wire                 mem_we;
    wire [ADDR_WIDTH-1:0] mem_addr;
    wire [DATA_WIDTH-1:0] mem_wdata;
    wire [DATA_WIDTH-1:0] mem_rdata;
    wire                 mem_ack;

    // Profiler
    wire                 prefetch_hit;

    // Memory latency switch
    reg [1:0] latency_sel;

    // Counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer cycle_count = 0;

    // 100 MHz clock (10 ns period)
    always #5 clk = ~clk;

    // ------------------------------------------------------------------------
    // Instantiate DUT (prefetcher.v)
    // ------------------------------------------------------------------------
    prefetcher #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .PF_ENTRIES (1),
        .RPT_ENTRIES(8)
    ) dut (
        .clk          (clk),
        .rst          (rst),
        .prefetch_en  (prefetch_en),
        .cache_bypass (cache_bypass),
        .is_load      (is_load),
        .load_pc      (load_pc),
        .load_addr    (load_addr),
        .load_stall   (load_stall),
        .store_valid  (store_valid),
        .store_addr   (store_addr),
        .l1_idle      (l1_idle),
        .l1_tag_hit   (l1_tag_hit),
        .l1_mem_req   (l1_mem_req),
        .l1_mem_we    (l1_mem_we),
        .l1_mem_addr  (l1_mem_addr),
        .l1_mem_wdata (l1_mem_wdata),
        .l1_mem_rdata (l1_mem_rdata),
        .l1_mem_ack   (l1_mem_ack),
        .main_mem_req (mem_req),
        .main_mem_we  (mem_we),
        .main_mem_addr(mem_addr),
        .main_mem_wdata(mem_wdata),
        .main_mem_rdata(mem_rdata),
        .main_mem_ack (mem_ack),
        .prefetch_hit (prefetch_hit)
    );

    // ------------------------------------------------------------------------
    // Instantiate Configurable-Latency Main Memory Model
    // ------------------------------------------------------------------------
    main_memory #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .MEM_BYTES (16384),
        .LATENCY   (10)
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

    // ------------------------------------------------------------------------
    // Helper task: Simulate a serviced load instruction in EX stage
    // ------------------------------------------------------------------------
    task send_load(input [31:0] pc, input [31:0] addr);
    begin
        @(posedge clk);
        is_load    <= 1'b1;
        load_pc    <= pc;
        load_addr  <= addr;
        load_stall <= 1'b0;
        l1_idle    <= 1'b1;
        @(posedge clk);
        is_load    <= 1'b0;
    end
    endtask

    // Helper task: Simulate a committed store instruction
    task send_store(input [31:0] addr);
    begin
        @(posedge clk);
        store_valid <= 1'b1;
        store_addr  <= addr;
        @(posedge clk);
        store_valid <= 1'b0;
    end
    endtask

    // Helper task: Reset system cleanly
    task reset_dut;
    begin
        @(posedge clk);
        rst <= 1'b1;
        prefetch_en <= 1'b1;
        cache_bypass <= 1'b0;
        is_load <= 1'b0;
        load_pc <= 32'd0;
        load_addr <= 32'd0;
        load_stall <= 1'b0;
        store_valid <= 1'b0;
        store_addr <= 32'd0;
        l1_idle <= 1'b1;
        l1_tag_hit <= 1'b0;
        l1_mem_req <= 1'b0;
        l1_mem_we <= 1'b0;
        l1_mem_addr <= 32'd0;
        l1_mem_wdata <= 128'd0;
        latency_sel <= 2'b01; // N=10
        @(posedge clk);
        @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);
    end
    endtask

    integer wait_cycles;
    integer lat_idx;
    reg [1:0] lat_codes [0:3];
    integer lat_vals [0:3];

    initial begin
        lat_codes[0] = 2'b00; lat_vals[0] = 1;
        lat_codes[1] = 2'b01; lat_vals[1] = 10;
        lat_codes[2] = 2'b10; lat_vals[2] = 100;
        lat_codes[3] = 2'b11; lat_vals[3] = 200;

        clk = 0;
        rst = 1;

        $display("==================================================================");
        $display("  STRIDE PREFETCHER UNIT VERIFICATION (tb_prefetcher.v)");
        $display("  Author: Archit (Group 14)");
        $display("==================================================================");

        // --------------------------------------------------------------------
        // TEST 1: Constant stride +16 detected after expected training accesses
        // --------------------------------------------------------------------
        $display("\n--- TEST 1: Constant Stride +16 Detection ---");
        reset_dut();
        // Access 1: Init (PC=0x00001000, Addr=0x0100)
        send_load(32'h0000_1000, 32'h0000_0100);
        // Access 2: Stride +16 recorded, conf=INIT
        send_load(32'h0000_1000, 32'h0000_0110);
        // Access 3: Stride +16 repeated, conf=TRANSIENT
        send_load(32'h0000_1000, 32'h0000_0120);
        // Access 4: Stride +16 repeated, conf=STEADY -> Prediction generated for 0x0140!
        send_load(32'h0000_1000, 32'h0000_0130);

        // Wait for prefetch to issue and complete to main memory
        wait_cycles = 0;
        while (!dut.pf_valid && wait_cycles < 30) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end

        if (dut.pf_valid && (dut.pf_tag == 28'h0000_014)) begin
            $display("[PASS] TEST 1: Stride +16 trained to STEADY, target line 0x00000140 prefetched!");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TEST 1: Target line 0x00000140 not prefetched! pf_valid=%b, pf_tag=0x%07x",
                     dut.pf_valid, dut.pf_tag);
            fail_count = fail_count + 1;
        end

        // --------------------------------------------------------------------
        // TEST 2: Constant stride +32 detected
        // --------------------------------------------------------------------
        $display("\n--- TEST 2: Constant Stride +32 Detection ---");
        reset_dut();
        send_load(32'h0000_2004, 32'h0000_0300);
        send_load(32'h0000_2004, 32'h0000_0320);
        send_load(32'h0000_2004, 32'h0000_0340);
        send_load(32'h0000_2004, 32'h0000_0360);

        wait_cycles = 0;
        while (!dut.pf_valid && wait_cycles < 30) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end

        if (dut.pf_valid && (dut.pf_tag == 28'h0000_038)) begin
            $display("[PASS] TEST 2: Stride +32 trained to STEADY, target line 0x00000380 prefetched!");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TEST 2: Target line 0x00000380 not prefetched! pf_valid=%b, pf_tag=0x%07x",
                     dut.pf_valid, dut.pf_tag);
            fail_count = fail_count + 1;
        end

        // --------------------------------------------------------------------
        // TEST 3: Constant stride -16 (negative) detected
        // --------------------------------------------------------------------
        $display("\n--- TEST 3: Constant Stride -16 (Negative) Detection ---");
        reset_dut();
        send_load(32'h0000_3008, 32'h0000_0500);
        send_load(32'h0000_3008, 32'h0000_04F0);
        send_load(32'h0000_3008, 32'h0000_04E0);
        send_load(32'h0000_3008, 32'h0000_04D0);

        wait_cycles = 0;
        while (!dut.pf_valid && wait_cycles < 30) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end

        if (dut.pf_valid && (dut.pf_tag == 28'h0000_04C)) begin
            $display("[PASS] TEST 3: Negative Stride -16 trained to STEADY, target line 0x000004C0 prefetched!");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TEST 3: Target line 0x000004C0 not prefetched! pf_valid=%b, pf_tag=0x%07x",
                     dut.pf_valid, dut.pf_tag);
            fail_count = fail_count + 1;
        end

        // --------------------------------------------------------------------
        // TEST 4: Stride change -> retraining
        // --------------------------------------------------------------------
        $display("\n--- TEST 4: Stride Change -> Retraining Verification ---");
        // Currently PC 0x3008 is STEADY at -16. Change stride by accessing 0x0600 (+0x130)
        send_load(32'h0000_3008, 32'h0000_0600);
        @(posedge clk);
        // Check confidence reset to CONF_INIT
        if (dut.rpt_conf[2] == 2'd0) begin
            $display("[PASS] TEST 4: Stride change detected, confidence correctly reset to CONF_INIT!");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TEST 4: Confidence not reset on stride change! conf=%0d", dut.rpt_conf[2]);
            fail_count = fail_count + 1;
        end

        // --------------------------------------------------------------------
        // TEST 5: Zero stride -> ignored (no prefetch)
        // --------------------------------------------------------------------
        $display("\n--- TEST 5: Zero Stride Ignored Verification ---");
        reset_dut();
        send_load(32'h0000_400C, 32'h0000_0700);
        send_load(32'h0000_400C, 32'h0000_0700);
        send_load(32'h0000_400C, 32'h0000_0700);
        send_load(32'h0000_400C, 32'h0000_0700);
        repeat(5) @(posedge clk);

        if (!dut.pf_valid && !mem_req && (dut.rpt_conf[3] == 2'd0)) begin
            $display("[PASS] TEST 5: Zero stride correctly ignored, no prefetch request issued!");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TEST 5: Zero stride caused unexpected activity! pf_valid=%b, conf=%0d",
                     dut.pf_valid, dut.rpt_conf[3]);
            fail_count = fail_count + 1;
        end

        // --------------------------------------------------------------------
        // TEST 6: Two interleaved PCs with different strides
        // --------------------------------------------------------------------
        $display("\n--- TEST 6: Two Interleaved PCs with Independent Strides ---");
        reset_dut();
        // PC_A = 0x1004 (Index 1), Stride = +16
        // PC_B = 0x1008 (Index 2), Stride = +32
        send_load(32'h0000_1004, 32'h0000_0100);
        send_load(32'h0000_1008, 32'h0000_0800);

        send_load(32'h0000_1004, 32'h0000_0110);
        send_load(32'h0000_1008, 32'h0000_0820);

        send_load(32'h0000_1004, 32'h0000_0120);
        send_load(32'h0000_1008, 32'h0000_0840);

        send_load(32'h0000_1004, 32'h0000_0130);
        send_load(32'h0000_1008, 32'h0000_0860);
        @(posedge clk);

        if ((dut.rpt_conf[1] == 2'd2) && (dut.rpt_stride[1] == 16'sd16) &&
            (dut.rpt_conf[2] == 2'd2) && (dut.rpt_stride[2] == 16'sd32)) begin
            $display("[PASS] TEST 6: Interleaved PCs independently trained! PC_A (+16) & PC_B (+32) both STEADY!");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TEST 6: Interleaved training mismatch! conf1=%0d s1=%0d, conf2=%0d s2=%0d",
                     dut.rpt_conf[1], dut.rpt_stride[1], dut.rpt_conf[2], dut.rpt_stride[2]);
            fail_count = fail_count + 1;
        end

        // --------------------------------------------------------------------
        // TEST 7: PC Aliasing (same index, different tags)
        // --------------------------------------------------------------------
        $display("\n--- TEST 7: PC Aliasing Isolation ---");
        reset_dut();
        // PC 1: 0x0000_0004 (Index 1, Tag 0)
        send_load(32'h0000_0004, 32'h0000_0100);
        send_load(32'h0000_0004, 32'h0000_0110);
        // PC 2: 0x0000_0404 (Index 1, Tag 0x20) -> Aliases to Index 1!
        send_load(32'h0000_0404, 32'h0000_0900);
        @(posedge clk);

        // Entry 1 should now be assigned to Tag 0x20 with conf=INIT
        if ((dut.rpt_pc_tag[1] == 10'h020) && (dut.rpt_conf[1] == 2'd0) && (dut.rpt_last_addr[1] == 32'h0000_0900)) begin
            $display("[PASS] TEST 7: PC aliasing safely evicted old PC entry, confidence reset to INIT (no wrong data)!");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TEST 7: Aliasing handling mismatch! tag=0x%03x conf=%0d",
                     dut.rpt_pc_tag[1], dut.rpt_conf[1]);
            fail_count = fail_count + 1;
        end

        // --------------------------------------------------------------------
        // TEST 8: Prefetch target already in L1 -> no request issued
        // --------------------------------------------------------------------
        $display("\n--- TEST 8: Target Already in L1 Filter ---");
        reset_dut();
        send_load(32'h0000_5010, 32'h0000_0200);
        send_load(32'h0000_5010, 32'h0000_0210);
        send_load(32'h0000_5010, 32'h0000_0220);

        // On the 4th access, assert l1_tag_hit = 1
        @(posedge clk);
        is_load    <= 1'b1;
        load_pc    <= 32'h0000_5010;
        load_addr  <= 32'h0000_0230;
        load_stall <= 1'b0;
        l1_idle    <= 1'b1;
        l1_tag_hit <= 1'b1; // Target line 0x240 is already in L1!
        @(posedge clk);
        is_load    <= 1'b0;
        l1_tag_hit <= 1'b0;

        repeat(5) @(posedge clk);

        if (!dut.pf_valid && !mem_req && !dut.pending_valid) begin
            $display("[PASS] TEST 8: Target line already in L1 -> prefetch request successfully suppressed!");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TEST 8: Prefetch was issued despite target being in L1!");
            fail_count = fail_count + 1;
        end

        // --------------------------------------------------------------------
        // TEST 9: Store to buffered line -> invalidates it
        // --------------------------------------------------------------------
        $display("\n--- TEST 9: Store Coherence Invalidation ---");
        reset_dut();
        // Train and prefetch line 0x0140 into buffer
        send_load(32'h0000_1000, 32'h0000_0100);
        send_load(32'h0000_1000, 32'h0000_0110);
        send_load(32'h0000_1000, 32'h0000_0120);
        send_load(32'h0000_1000, 32'h0000_0130);

        wait_cycles = 0;
        while (!dut.pf_valid && wait_cycles < 30) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end

        if (dut.pf_valid) begin
            $display("[INFO] Line 0x%07x0 successfully loaded in prefetch buffer.", dut.pf_tag);
            // Now execute store to word within the same 16-byte block (0x0000_0144)
            send_store(32'h0000_0144);
            @(posedge clk);

            if (!dut.pf_valid) begin
                $display("[PASS] TEST 9: Store to buffered line successfully invalidated prefetch buffer!");
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] TEST 9: Prefetch buffer remained valid after store hit!");
                fail_count = fail_count + 1;
            end
        end else begin
            $display("[FAIL] TEST 9: Failed to fill prefetch buffer prior to store test!");
            fail_count = fail_count + 1;
        end

        // --------------------------------------------------------------------
        // TEST 10: In-Flight Prefetch vs Demand Miss (Merge vs Non-Merge)
        //          across N = 1, 10, 100, 200 cycles
        // --------------------------------------------------------------------
        $display("\n--- TEST 10: In-Flight Prefetch Arbitration & Merge (N = 1, 10, 100, 200) ---");

        for (lat_idx = 0; lat_idx < 4; lat_idx = lat_idx + 1) begin
            latency_sel = lat_codes[lat_idx];
            $display("[TEST 10.%0d] Testing with Memory Latency N = %0d cycles...", lat_idx+1, lat_vals[lat_idx]);

            // 10A: Same-line demand miss merges with in-flight prefetch
            reset_dut();
            latency_sel = lat_codes[lat_idx];

            // Train PC to generate prefetch for line 0x0140
            send_load(32'h0000_1000, 32'h0000_0100);
            send_load(32'h0000_1000, 32'h0000_0110);
            send_load(32'h0000_1000, 32'h0000_0120);
            send_load(32'h0000_1000, 32'h0000_0130);

            // Wait until prefetch is in flight
            while (!dut.inflight) @(posedge clk);

            // CPU demands the same line (0x0140) while prefetch is in-flight!
            @(posedge clk);
            l1_mem_req  <= 1'b1;
            l1_mem_we   <= 1'b0;
            l1_mem_addr <= 32'h0000_0140;

            // Wait for completion
            while (!l1_mem_ack) @(posedge clk);

            if (l1_mem_ack && prefetch_hit) begin
                $display("       [PASS] Same-line demand miss merged with in-flight prefetch at N=%0d!", lat_vals[lat_idx]);
                pass_count = pass_count + 1;
            end else begin
                $display("       [FAIL] Same-line merge failed at N=%0d! ack=%b, hit=%b",
                         lat_vals[lat_idx], l1_mem_ack, prefetch_hit);
                fail_count = fail_count + 1;
            end
            l1_mem_req <= 1'b0;

            // 10B: Different-line demand miss during in-flight prefetch (no deadlock)
            reset_dut();
            latency_sel = lat_codes[lat_idx];

            send_load(32'h0000_1000, 32'h0000_0100);
            send_load(32'h0000_1000, 32'h0000_0110);
            send_load(32'h0000_1000, 32'h0000_0120);
            send_load(32'h0000_1000, 32'h0000_0130);

            while (!dut.inflight) @(posedge clk);

            // CPU demands a DIFFERENT line (0x0780)
            @(posedge clk);
            l1_mem_req  <= 1'b1;
            l1_mem_we   <= 1'b0;
            l1_mem_addr <= 32'h0000_0780;

            // Wait for L1 demand miss to be satisfied
            wait_cycles = 0;
            while (!l1_mem_ack && wait_cycles < (lat_vals[lat_idx] * 3 + 20)) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end

            if (l1_mem_ack) begin
                $display("       [PASS] Different-line demand miss serviced without deadlock at N=%0d!", lat_vals[lat_idx]);
                pass_count = pass_count + 1;
            end else begin
                $display("       [FAIL] Deadlock on different-line demand miss at N=%0d!", lat_vals[lat_idx]);
                fail_count = fail_count + 1;
            end
            l1_mem_req <= 1'b0;
        end

        // --------------------------------------------------------------------
        // TEST 11: Prefetch buffer hit latency <= 2 cycles
        // --------------------------------------------------------------------
        $display("\n--- TEST 11: Prefetch Buffer Hit Latency (<= 2 cycles) ---");
        reset_dut();
        latency_sel = 2'b01; // N=10

        // Train and buffer line 0x0140
        send_load(32'h0000_1000, 32'h0000_0100);
        send_load(32'h0000_1000, 32'h0000_0110);
        send_load(32'h0000_1000, 32'h0000_0120);
        send_load(32'h0000_1000, 32'h0000_0130);

        wait_cycles = 0;
        while (!dut.pf_valid && wait_cycles < 30) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end

        if (dut.pf_valid) begin
            // Measure latency: assert l1_mem_req for buffered line
            @(posedge clk);
            l1_mem_req  <= 1'b1;
            l1_mem_we   <= 1'b0;
            l1_mem_addr <= 32'h0000_0140;

            // Check hit response
            @(posedge clk);
            if (l1_mem_ack && prefetch_hit) begin
                $display("[PASS] TEST 11: Prefetch buffer hit returned in <= 2 cycles (l1_mem_ack asserted, pf_hit strobe active)!");
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] TEST 11: Buffer hit took more than 2 cycles! ack=%b, hit=%b", l1_mem_ack, prefetch_hit);
                fail_count = fail_count + 1;
            end
            l1_mem_req <= 1'b0;
        end else begin
            $display("[FAIL] TEST 11: Prefetch buffer was not valid!");
            fail_count = fail_count + 1;
        end

        // --------------------------------------------------------------------
        // TEST 12: SW[8] = 0 -> Zero prefetch activity
        // --------------------------------------------------------------------
        $display("\n--- TEST 12: SW[8]=0 Zero Activity Verification ---");
        reset_dut();
        prefetch_en = 1'b0; // SW[8] = 0 (Disabled)

        // Perform 6 consecutive strided loads
        send_load(32'h0000_1000, 32'h0000_0100);
        send_load(32'h0000_1000, 32'h0000_0110);
        send_load(32'h0000_1000, 32'h0000_0120);
        send_load(32'h0000_1000, 32'h0000_0130);
        send_load(32'h0000_1000, 32'h0000_0140);
        send_load(32'h0000_1000, 32'h0000_0150);

        repeat(10) @(posedge clk);

        if (!dut.pf_valid && !mem_req && !prefetch_hit && !dut.pending_valid && !dut.rpt_valid[0]) begin
            $display("[PASS] TEST 12: SW[8]=0 confirmed ZERO prefetch activity, tables held in reset!");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TEST 12: SW[8]=0 leaked activity! pf_valid=%b, mem_req=%b, rpt_valid=%b",
                     dut.pf_valid, mem_req, dut.rpt_valid[0]);
            fail_count = fail_count + 1;
        end

        // --------------------------------------------------------------------
        // Summary
        // --------------------------------------------------------------------
        #100;
        $display("\n==================================================================");
        $display("  STRIDE PREFETCHER VERIFICATION COMPLETED");
        $display("  TOTAL TESTS PASSED: %0d", pass_count);
        $display("  TOTAL TESTS FAILED: %0d", fail_count);
        if (fail_count == 0)
            $display("  STATUS: ALL PREFETCHER TESTS PASSED SUCCESSFULLY!");
        else
            $display("  STATUS: FAILURES DETECTED IN PREFETCHER TESTS.");
        $display("==================================================================");
        $finish;
    end

endmodule
