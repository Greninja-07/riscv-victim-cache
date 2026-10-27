`timescale 1ns / 1ps

// ============================================================================
// Testbench: tb_system
// Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher
// Author: Abhishek Kumar (Group 14)
//
// Description:
//   Full-System End-to-End Simulation Testbench:
//   - RV32IM Pipelined CPU Core (pipe.v)
//   - 16 KB Synchronous Instruction Memory (instr_mem)
//   - Memory Subsystem (mem_subsystem.v: L1 Cache + Configurable Latency Memory)
//   - Hardware Performance Profiler (perf_profiler.v: 6 saturating counters + 7-seg)
//   - Supports runtime parameters: +CACHE_BYPASS=0/1, +LATENCY=0/1/2/3, +MAXC=num
// ============================================================================

module tb_system;

    parameter MEM_BYTES  = 16384;
    parameter IMEM_HEX   = "imem.hex";
    parameter DMEM_HEX   = "dmem.hex";
    parameter MEM128_HEX = "mem128.hex";

    reg clk;
    reg rst_n;

    // Runtime switches
    reg [1:0] latency_sel;
    reg       cache_bypass;
    reg [2:0] prof_sw;

    // CPU wires
    wire        exception;
    wire [31:0] pc_out;
    wire [31:0] inst_mem_read_data;
    wire [31:0] dmem_read_data;
    wire        dmem_stall;
    wire        dmem_read_ready;
    wire [31:0] dmem_read_address;
    wire        dmem_write_ready;
    wire [31:0] dmem_write_address;
    wire [31:0] dmem_write_data;
    wire [ 3:0] dmem_write_byte;

    // Profiler wires
    wire l1_access;
    wire l1_hit;
    wire l1_miss;
    wire vc_hit;
    wire mem_stall;
    wire [6:0] seg;
    wire [7:0] an;
    wire       dp;
    wire       frozen;

    // Mailbox completion detection
    reg done;
    reg [31:0] result_val;
    integer cyc;
    integer maxc;
    integer arg_bypass;
    integer arg_lat;

    // 100 MHz clock
    always #5 clk = ~clk;

    // ------------------------------------------------------------------------
    // Instantiate 3-Stage RV32IM CPU Pipeline
    // ------------------------------------------------------------------------
    pipe #(
        .RESET   (32'h0000_0000),
        .MUL_FAST(1)
    ) cpu (
        .clk                (clk),
        .reset              (rst_n),
        .stall              (dmem_stall),
        .exception          (exception),
        .pc_out             (pc_out),
        .inst_mem_is_valid  (1'b1),
        .inst_mem_read_data (inst_mem_read_data),
        .dmem_read_data_temp(dmem_read_data),
        .dmem_write_valid   (1'b1),
        .dmem_read_valid    (1'b1),
        .dmem_read_ready    (dmem_read_ready),
        .dmem_read_address  (dmem_read_address),
        .dmem_write_ready   (dmem_write_ready),
        .dmem_write_address (dmem_write_address),
        .dmem_write_data    (dmem_write_data),
        .dmem_write_byte    (dmem_write_byte)
    );

    // ------------------------------------------------------------------------
    // Instantiate 16 KB Instruction Memory
    // ------------------------------------------------------------------------
    instr_mem #(
        .MEM_BYTES(MEM_BYTES),
        .HEX_FILE (IMEM_HEX)
    ) imem (
        .clk  (clk),
        .pc   (pc_out),
        .instr(inst_mem_read_data)
    );

    // ------------------------------------------------------------------------
    // Instantiate Unified Memory Subsystem (L1 Data Cache + Main Memory)
    // ------------------------------------------------------------------------
    mem_subsystem #(
        .ADDR_WIDTH (32),
        .DATA_WIDTH (32),
        .MEM_BYTES  (MEM_BYTES),
        .INIT_FILE  (MEM128_HEX),
        .LATENCY    (10)
    ) mem_sys (
        .clk                 (clk),
        .rst                 (~rst_n),
        .latency_sel         (latency_sel),
        .cache_bypass        (cache_bypass),
        .victim_cache_en     (1'b1),
        .dmem_read_ready     (dmem_read_ready),
        .dmem_read_address   (dmem_read_address),
        .dmem_write_ready    (dmem_write_ready),
        .dmem_write_address  (dmem_write_address),
        .dmem_write_data     (dmem_write_data),
        .dmem_write_byte     (dmem_write_byte),
        .dmem_read_data      (dmem_read_data),
        .dmem_stall          (dmem_stall),
        .l1_access           (l1_access),
        .l1_hit              (l1_hit),
        .l1_miss             (l1_miss),
        .vc_hit              (vc_hit),
        .mem_stall           (mem_stall),
        .prefetch_snoop_valid(),
        .prefetch_snoop_addr (),
        .prefetch_snoop_miss (),
        .prefetch_req        (1'b0),
        .prefetch_addr       (32'b0),
        .prefetch_data       (128'b0),
        .prefetch_ack        ()
    );

    // ------------------------------------------------------------------------
    // Instantiate 6-Counter Hardware Performance Profiler
    // ------------------------------------------------------------------------
    perf_profiler #(
        .REFRESH_BITS(4) // Fast refresh for simulation
    ) profiler (
        .clk         (clk),
        .rst         (~rst_n),
        .done        (done),
        .mem_stall   (mem_stall),
        .l1_access   (l1_access),
        .l1_hit      (l1_hit),
        .l1_miss     (l1_miss),
        .victim_hit  (vc_hit),
        .prefetch_hit(1'b0),
        .sw          (prof_sw),
        .seg         (seg),
        .an          (an),
        .dp          (dp),
        .frozen      (frozen)
    );

    // ------------------------------------------------------------------------
    // Simulation Control & Mailbox Monitoring
    // ------------------------------------------------------------------------
    initial begin
        clk          = 0;
        rst_n        = 0;
        done         = 0;
        cyc          = 0;
        result_val   = 0;
        prof_sw      = 3'b000;

        if (!$value$plusargs("MAXC=%d", maxc)) maxc = 50000;
        if ($value$plusargs("CACHE_BYPASS=%d", arg_bypass))
            cache_bypass = (arg_bypass != 0);
        else
            cache_bypass = 1'b0;

        if ($value$plusargs("LATENCY=%d", arg_lat))
            latency_sel = arg_lat[1:0];
        else
            latency_sel = 2'b10; // Default N = 100

        #22;
        @(posedge clk);
        rst_n = 1;
    end

    // Monitor memory stores to catch mailbox termination (0x1F8 = done flag, 0x1FC = result)
    always @(posedge clk) begin
        if (rst_n) begin
            cyc <= cyc + 1;

            if (dmem_write_ready && !dmem_stall) begin
                if (dmem_write_address == 32'h0000_01FC) begin
                    result_val <= dmem_write_data;
                end
                if (dmem_write_address == 32'h0000_01F8 && dmem_write_data == 32'h0000_0001) begin
                    done <= 1'b1;
                end
            end

            // When done is asserted, wait 5 cycles to freeze profiler and print results
            if (done) begin
                @(posedge clk);
                @(posedge clk);
                @(posedge clk);
                @(posedge clk);
                @(posedge clk);
                $display("==================================================================");
                $display("  PROGRAM EXECUTION FINISHED");
                $display("==================================================================");
                $display("  Status           : SUCCESS (Mailbox Done Flag Asserted)");
                $display("  Mailbox Result   : 0x%08x (%0d)", result_val, result_val);
                $display("  Total Cycles     : %0d", profiler.total_cycles);
                $display("  Mem Stall Cycles : %0d", profiler.stall_cycles);
                $display("  L1 Accesses      : %0d", profiler.l1_accesses);
                $display("  L1 Hits          : %0d", profiler.l1_accesses - profiler.l1_misses);
                $display("  L1 Misses        : %0d", profiler.l1_misses);
                if (profiler.l1_accesses > 0) begin
                    $display("  L1 Hit Rate      : %0.2f %%", ((profiler.l1_accesses - profiler.l1_misses) * 100.0) / profiler.l1_accesses);
                end
                $display("  Cache Bypass     : %0d", cache_bypass);
                $display("  Latency Setting  : %b", latency_sel);
                $display("==================================================================");
                $finish;
            end

            if (cyc >= maxc) begin
                $display("[TIMEOUT] Simulation reached max cycles %0d without done assertion", maxc);
                $finish;
            end
        end
    end

endmodule
