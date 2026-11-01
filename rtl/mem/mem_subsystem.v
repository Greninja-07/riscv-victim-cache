`timescale 1ns / 1ps

// ============================================================================
// Module: mem_subsystem
// Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher
// Author: Abhishek Kumar (Group 14)
//
// Description:
//   Unified synthesizable Memory Subsystem bridging the RV32I CPU core to the
//   entire memory hierarchy:
//   - 2 KB Direct-Mapped L1 Data Cache (l1_cache_controller.v)
//   - 4-Entry Fully-Associative Victim Cache with True LRU (victim_cache.v)
//   - Configurable-Latency Main Memory Model (main_memory.v)
//   - Hardware Cache-Bypass Mode (SW[2]) for cache ON/OFF benchmarking
//   - Switch-selectable Memory Latency (SW[1:0]: N = 1, 10, 100, 200 cycles)
//   - Load/Store arbitration between EX stage (load) and WB stage (store)
//   - Performance Profiler event strobes for hardware counters
//   - Frozen interconnect ports for Stride Prefetcher (Week 5)
// ============================================================================

module mem_subsystem #(
    parameter ADDR_WIDTH  = 32,
    parameter DATA_WIDTH  = 32,
    parameter MEM_BYTES   = 16384,
    parameter INIT_FILE   = "",
    parameter LATENCY     = 10
)(
    input  wire                   clk,
    input  wire                   rst,

    // Runtime switches from FPGA board
    input  wire [1:0]             latency_sel,   // SW[1:0]: N=1, 10, 100, 200 cycles
    input  wire                   cache_bypass,  // SW[2]: 0=L1 Cache, 1=Bypass directly to main memory
    input  wire                   victim_cache_en,// Switch/enable for victim cache (default 1)
    input  wire                   prefetch_en,    // SW[8]: 1=Enable prefetcher, 0=Disabled
    input  wire [ADDR_WIDTH-1:0]  load_pc,        // PC of the load instruction
    input  wire                   is_load,        // Load instruction indicator
    output wire                   prefetch_hit,   // Pulse to performance profiler

    // CPU Data Memory Interface (from pipeline.v)
    input  wire                   dmem_read_ready,
    input  wire [ADDR_WIDTH-1:0]  dmem_read_address,
    input  wire                   dmem_write_ready,
    input  wire [ADDR_WIDTH-1:0]  dmem_write_address,
    input  wire [DATA_WIDTH-1:0]  dmem_write_data,
    input  wire [3:0]             dmem_write_byte,
    output reg  [DATA_WIDTH-1:0]  dmem_read_data,
    output wire                   dmem_stall,

    // Performance Profiler Strobes (to Archit's perf_profiler.v)
    output wire                   l1_access,
    output wire                   l1_hit,
    output wire                   l1_miss,
    output wire                   vc_hit,
    output wire                   mem_stall,

    // Stride Prefetcher Interconnect (ready for Archit's Prefetcher in Week 5)
    output wire                   prefetch_snoop_valid,
    output wire [ADDR_WIDTH-1:0]  prefetch_snoop_addr,
    output wire                   prefetch_snoop_miss,
    input  wire                   prefetch_req,
    input  wire [ADDR_WIDTH-1:0]  prefetch_addr,
    input  wire [127:0]           prefetch_data,
    output wire                   prefetch_ack
);

    // ------------------------------------------------------------------------
    // Interconnect wires between L1 Cache Controller, Victim Cache, & Memory
    // ------------------------------------------------------------------------
    wire                  l1_to_mem_req;
    wire                  l1_to_mem_we;
    wire [ADDR_WIDTH-1:0] l1_to_mem_addr;
    wire [127:0]          l1_to_mem_wdata;
    wire [127:0]          l1_to_mem_rdata;
    wire                  l1_to_mem_ack;

    wire                  main_mem_req;
    wire                  main_mem_we;
    wire [ADDR_WIDTH-1:0] main_mem_addr;
    wire [127:0]          main_mem_wdata;
    wire [127:0]          main_mem_rdata;
    wire                  main_mem_ack;

    // Victim Cache Interconnect
    wire [ADDR_WIDTH-1:0] victim_lookup_addr;
    wire                  vc_hit_raw;
    wire [127:0]          victim_hit_data;
    wire                  victim_evict_valid;
    wire                  victim_swap_valid;
    wire [ADDR_WIDTH-1:0] victim_evict_addr;
    wire [127:0]          victim_evict_data;
    wire                  vc_hit_o;
    wire                  victim_hit_effective = victim_cache_en ? vc_hit_raw : 1'b0;

    assign vc_hit = vc_hit_o;

    // L1 CPU Interface
    reg                   l1_cpu_req;
    reg                   l1_cpu_we;
    reg  [ADDR_WIDTH-1:0] l1_cpu_addr;
    reg  [DATA_WIDTH-1:0] l1_cpu_wdata;
    reg  [3:0]            l1_cpu_wmask;
    wire [DATA_WIDTH-1:0] l1_cpu_rdata;
    wire                  l1_cpu_stall;

    // ------------------------------------------------------------------------
    // CPU Load / Store Port Arbitration with Store-Commit State
    // Priority:
    //   1. Store in WB stage (dmem_write_ready) - commits first (stalling load for 1 cycle)
    //   2. Once store completes, service Load in EX stage (dmem_read_ready)
    // ------------------------------------------------------------------------
    reg store_serviced;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            store_serviced <= 1'b0;
        end else begin
            if (dmem_write_ready && dmem_read_ready && !l1_cpu_stall && !store_serviced) begin
                store_serviced <= 1'b1;
            end else if (!dmem_stall || !dmem_read_ready) begin
                store_serviced <= 1'b0;
            end
        end
    end

    wire structural_hazard = (dmem_write_ready && dmem_read_ready && !store_serviced);

    always @(*) begin
        if (dmem_write_ready && !store_serviced) begin
            l1_cpu_req   = 1'b1;
            l1_cpu_we    = 1'b1;
            l1_cpu_addr  = dmem_write_address;
            l1_cpu_wdata = dmem_write_data;
            l1_cpu_wmask = dmem_write_byte;
        end else if (dmem_read_ready) begin
            l1_cpu_req   = 1'b1;
            l1_cpu_we    = 1'b0;
            l1_cpu_addr  = dmem_read_address;
            l1_cpu_wdata = {DATA_WIDTH{1'b0}};
            l1_cpu_wmask = 4'b0000;
        end else begin
            l1_cpu_req   = 1'b0;
            l1_cpu_we    = 1'b0;
            l1_cpu_addr  = {ADDR_WIDTH{1'b0}};
            l1_cpu_wdata = {DATA_WIDTH{1'b0}};
            l1_cpu_wmask = 4'b0000;
        end
    end

    // Unified memory stall asserted to CPU pipeline
    assign dmem_stall = l1_cpu_stall || structural_hazard;
    assign mem_stall  = dmem_stall;

    // ------------------------------------------------------------------------
    // Synchronous Read Data Register (Matches RV32I 3-stage pipeline timing)
    // When a Load executes in EX, data is registered and presented in WB stage
    // ------------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            dmem_read_data <= {DATA_WIDTH{1'b0}};
        end else if (!dmem_stall) begin
            dmem_read_data <= l1_cpu_rdata;
        end
    end

    // ------------------------------------------------------------------------
    // 1. Instantiate 2 KB Direct-Mapped L1 Data Cache Controller
    // ------------------------------------------------------------------------
    l1_cache_controller #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .BLOCK_WORDS(4),
        .BLOCK_BITS (4),
        .INDEX_BITS (7)
    ) l1_cache (
        .clk                 (clk),
        .rst                 (rst),
        .cpu_req             (l1_cpu_req),
        .cpu_we              (l1_cpu_we),
        .cpu_addr            (l1_cpu_addr),
        .cpu_wdata           (l1_cpu_wdata),
        .cpu_wmask           (l1_cpu_wmask),
        .cpu_rdata           (l1_cpu_rdata),
        .cpu_stall           (l1_cpu_stall),
        .cache_bypass        (cache_bypass),
        .l1_access           (l1_access),
        .l1_hit              (l1_hit),
        .l1_miss             (l1_miss),
        .vc_hit_o            (vc_hit_o),
        .mem_req             (l1_to_mem_req),
        .mem_we              (l1_to_mem_we),
        .mem_addr            (l1_to_mem_addr),
        .mem_wdata           (l1_to_mem_wdata),
        .mem_rdata           (l1_to_mem_rdata),
        .mem_ack             (l1_to_mem_ack),
        .victim_lookup_addr  (victim_lookup_addr),
        .victim_hit          (victim_hit_effective),
        .victim_hit_data     (victim_hit_data),
        .victim_evict_valid  (victim_evict_valid),
        .victim_swap_valid   (victim_swap_valid),
        .victim_evict_addr   (victim_evict_addr),
        .victim_evict_data   (victim_evict_data),
        .prefetch_snoop_valid(prefetch_snoop_valid),
        .prefetch_snoop_addr (prefetch_snoop_addr),
        .prefetch_snoop_miss (prefetch_snoop_miss),
        .prefetch_req        (prefetch_req),
        .prefetch_addr       (prefetch_addr),
        .prefetch_data       (prefetch_data),
        .prefetch_ack        (prefetch_ack)
    );

    // ------------------------------------------------------------------------
    // 2. Instantiate 4-Entry Fully-Associative Victim Cache
    // ------------------------------------------------------------------------
    victim_cache #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .BLOCK_WORDS(4),
        .BLOCK_BITS (4),
        .NUM_ENTRIES(4)
    ) vcache (
        .clk        (clk),
        .rst        (rst),
        .vc_en      (victim_cache_en),
        .lookup_addr(victim_lookup_addr),
        .vc_hit     (vc_hit_raw),
        .vc_hit_data(victim_hit_data),
        .evict_valid(victim_evict_valid && victim_cache_en),
        .swap_valid (victim_swap_valid && victim_cache_en),
        .evict_addr (victim_evict_addr),
        .evict_data (victim_evict_data)
    );

    // ------------------------------------------------------------------------
    // 3. Instantiate 2-Delta Hardware Stride Prefetcher
    // ------------------------------------------------------------------------
    wire l1_is_idle   = !l1_cpu_stall && !l1_to_mem_req;
    wire store_commit = dmem_write_ready && !l1_cpu_stall && !store_serviced;

    wire prefetch_en_safe = (prefetch_en === 1'b1);

    prefetcher #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (128),
        .PF_ENTRIES (1),
        .RPT_ENTRIES(8)
    ) prefetcher_inst (
        .clk          (clk),
        .rst          (rst),
        .prefetch_en  (prefetch_en_safe),
        .cache_bypass (cache_bypass),
        .is_load      (is_load),
        .load_pc      (load_pc),
        .load_addr    (dmem_read_address),
        .load_stall   (dmem_stall),
        .store_valid  (store_commit),
        .store_addr   (dmem_write_address),
        .l1_idle      (l1_is_idle),
        .l1_tag_hit   (1'b0),
        .l1_mem_req   (l1_to_mem_req),
        .l1_mem_we    (l1_to_mem_we),
        .l1_mem_addr  (l1_to_mem_addr),
        .l1_mem_wdata (l1_to_mem_wdata),
        .l1_mem_rdata (l1_to_mem_rdata),
        .l1_mem_ack   (l1_to_mem_ack),
        .main_mem_req (main_mem_req),
        .main_mem_we  (main_mem_we),
        .main_mem_addr(main_mem_addr),
        .main_mem_wdata(main_mem_wdata),
        .main_mem_rdata(main_mem_rdata),
        .main_mem_ack (main_mem_ack),
        .prefetch_hit (prefetch_hit)
    );

    // ------------------------------------------------------------------------
    // 4. Instantiate Configurable-Latency Main Memory Model
    // ------------------------------------------------------------------------
    main_memory #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (128),
        .MEM_BYTES  (MEM_BYTES),
        .LATENCY    (LATENCY),
        .INIT_FILE  (INIT_FILE)
    ) main_mem (
        .clk        (clk),
        .rst        (rst),
        .latency_sel(latency_sel),
        .mem_req    (main_mem_req),
        .mem_we     (main_mem_we),
        .mem_addr   (main_mem_addr),
        .mem_wdata  (main_mem_wdata),
        .mem_rdata  (main_mem_rdata),
        .mem_ack    (main_mem_ack)
    );

endmodule
