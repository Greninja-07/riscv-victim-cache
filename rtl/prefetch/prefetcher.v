`timescale 1ns / 1ps

// ============================================================================
// Module: prefetcher
// Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher
// Author: Archit & Team (Group 14)
//
// Description:
//   Hardware Stride Data Prefetcher with:
//   - 8-entry Reference Prediction Table (RPT) indexed by PC[4:2]
//   - 2-bit saturating confidence counter (INIT, TRANSIENT, STEADY, NO_PRED)
//   - Parameterizable 1-entry Prefetch Buffer (pf_valid, pf_tag[31:4], pf_data[127:0])
//   - Lowest priority memory arbitration to main_memory
//   - Bounded wait (<= N cycles) and same-line merge on demand miss during in-flight prefetch
//   - Fast prefetch buffer hit path (<= 2 stall cycles to CPU)
//   - Store coherence invalidation on store hits
//   - Fully disabled and held in reset when SW[8] (prefetch_en) = 0
//   - Idle during cache bypass (SW[2] = 1)
//   - Synchronous reset, no latches, Verilog-2001 synthesizable
// ============================================================================

module prefetcher #(
    parameter ADDR_WIDTH  = 32,
    parameter DATA_WIDTH  = 128,
    parameter PF_ENTRIES  = 1,
    parameter RPT_ENTRIES = 8
)(
    input  wire                  clk,
    input  wire                  rst,

    // Runtime Control Switches
    input  wire                  prefetch_en,   // SW[8]: 1 = Enable prefetcher, 0 = Disabled/Reset
    input  wire                  cache_bypass,  // SW[2]: 1 = Uncached bypass mode (prefetcher idle)

    // CPU / Pipeline Snoop for Training
    input  wire                  is_load,       // EX stage load instruction indicator
    input  wire [ADDR_WIDTH-1:0] load_pc,       // PC of the load instruction
    input  wire [ADDR_WIDTH-1:0] load_addr,     // Effective memory address of load
    input  wire                  load_stall,    // Pipeline stall (training occurs when !load_stall)

    // Store Coherence Invalidation Bus
    input  wire                  store_valid,   // Store commit pulse/strobe
    input  wire [ADDR_WIDTH-1:0] store_addr,    // Store address

    // L1 Cache Status
    input  wire                  l1_idle,       // L1 Cache Controller is in IDLE state
    input  wire                  l1_tag_hit,    // 1 if candidate prefetch target line is in L1

    // Demand Miss Memory Interface from L1 Cache Controller
    input  wire                  l1_mem_req,
    input  wire                  l1_mem_we,
    input  wire [ADDR_WIDTH-1:0] l1_mem_addr,
    input  wire [DATA_WIDTH-1:0] l1_mem_wdata,
    output wire [DATA_WIDTH-1:0] l1_mem_rdata,
    output wire                  l1_mem_ack,

    // Main Memory Bus Interconnect
    output wire                  main_mem_req,
    output wire                  main_mem_we,
    output wire [ADDR_WIDTH-1:0] main_mem_addr,
    output wire [DATA_WIDTH-1:0] main_mem_wdata,
    input  wire [DATA_WIDTH-1:0] main_mem_rdata,
    input  wire                  main_mem_ack,

    // Performance Profiler Strobe
    output wire                  prefetch_hit
);

    // ------------------------------------------------------------------------
    // Confidence States
    // ------------------------------------------------------------------------
    localparam CONF_INIT      = 2'd0;
    localparam CONF_TRANSIENT = 2'd1;
    localparam CONF_STEADY    = 2'd2;
    localparam CONF_NO_PRED   = 2'd3;

    // ------------------------------------------------------------------------
    // FSM States for Prefetcher Memory Arbiter
    // ------------------------------------------------------------------------
    localparam S_IDLE      = 1'b0;
    localparam S_PREF_WAIT = 1'b1;

    reg state;

    // ------------------------------------------------------------------------
    // 1. Reference Prediction Table (RPT): 8 entries
    // Index: PC[4:2] (3 bits)
    // Tag:   PC[14:5] (10 bits)
    // ------------------------------------------------------------------------
    reg                  rpt_valid     [0:RPT_ENTRIES-1];
    reg [9:0]            rpt_pc_tag    [0:RPT_ENTRIES-1];
    reg [ADDR_WIDTH-1:0] rpt_last_addr [0:RPT_ENTRIES-1];
    reg signed [15:0]    rpt_stride    [0:RPT_ENTRIES-1];
    reg [1:0]            rpt_conf      [0:RPT_ENTRIES-1];

    wire [2:0] train_idx = load_pc[4:2];
    wire [9:0] train_tag = load_pc[14:5];

    // Signed stride difference calculation
    wire signed [ADDR_WIDTH-1:0] diff_full = $signed(load_addr - rpt_last_addr[train_idx]);
    wire signed [15:0]           new_stride = diff_full[15:0];

    // Training condition: valid load instruction committed without pipeline stall
    wire train_fire = is_load && !load_stall && (prefetch_en == 1'b1) && !cache_bypass;

    // ------------------------------------------------------------------------
    // 2. Prefetch Buffer: 1 entry (PF_ENTRIES = 1)
    // ------------------------------------------------------------------------
    reg                  pf_valid;
    reg [ADDR_WIDTH-5:0] pf_tag;        // addr[31:4] (28 bits)
    reg [DATA_WIDTH-1:0] pf_data;

    // In-flight tracking registers
    reg                  inflight;
    reg [ADDR_WIDTH-5:0] inflight_tag;
    reg                  inflight_invalid;

    // Pending prefetch register
    reg                  pending_valid;
    reg [ADDR_WIDTH-1:0] pending_addr;

    // Delayed hit pulse for profiler
    reg                  pf_hit_pulse;

    // Check prefetch buffer hit on incoming L1 demand miss
    wire l1_hit_pf_buf = pf_valid && (pf_tag == l1_mem_addr[ADDR_WIDTH-1:4]) && !l1_mem_we && (prefetch_en == 1'b1) && !cache_bypass;

    // ------------------------------------------------------------------------
    // Prediction Logic (Combinational evaluation at training time)
    // ------------------------------------------------------------------------
    wire [ADDR_WIDTH-1:0] stride_ext = {{16{rpt_stride[train_idx][15]}}, rpt_stride[train_idx]};
    wire [ADDR_WIDTH-1:0] cand_target_addr = load_addr + stride_ext;
    wire [ADDR_WIDTH-1:0] cand_line_addr   = {cand_target_addr[ADDR_WIDTH-1:4], 4'b0000};
    wire target_in_range = (cand_line_addr < 32'd16384);

    reg cand_valid;
    always @(*) begin
        cand_valid = 1'b0;

        if (train_fire && target_in_range) begin
            // Check if entry is STEADY or will become STEADY on this access
            if (rpt_valid[train_idx] && (rpt_pc_tag[train_idx] == train_tag)) begin
                if ((rpt_conf[train_idx] == CONF_STEADY) ||
                    (rpt_conf[train_idx] == CONF_TRANSIENT && (new_stride == rpt_stride[train_idx]) && (new_stride != 16'sd0))) begin
                    
                    // Filter conditions:
                    // 1. Target line != current line
                    // 2. Target line not already in L1 (l1_tag_hit == 0)
                    // 3. Target line not in prefetch buffer
                    // 4. Target line not currently in-flight
                    if ((cand_line_addr[ADDR_WIDTH-1:4] != load_addr[ADDR_WIDTH-1:4]) &&
                        !l1_tag_hit &&
                        !(pf_valid && (pf_tag == cand_line_addr[ADDR_WIDTH-1:4])) &&
                        !(inflight && (inflight_tag == cand_line_addr[ADDR_WIDTH-1:4]))) begin
                        cand_valid = 1'b1;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Sequential Logic: RPT Training, Prefetch Buffer, & Memory Arbiter
    // ------------------------------------------------------------------------
    integer i;
    always @(posedge clk) begin
        if (rst || (prefetch_en != 1'b1)) begin
            state            <= S_IDLE;
            pf_valid         <= 1'b0;
            pf_tag           <= 28'd0;
            pf_data          <= {DATA_WIDTH{1'b0}};
            inflight         <= 1'b0;
            inflight_tag     <= 28'd0;
            inflight_invalid <= 1'b0;
            pending_valid    <= 1'b0;
            pending_addr     <= {ADDR_WIDTH{1'b0}};
            pf_hit_pulse     <= 1'b0;

            for (i = 0; i < RPT_ENTRIES; i = i + 1) begin
                rpt_valid[i]     <= 1'b0;
                rpt_pc_tag[i]    <= 10'd0;
                rpt_last_addr[i] <= {ADDR_WIDTH{1'b0}};
                rpt_stride[i]    <= 16'sd0;
                rpt_conf[i]      <= CONF_INIT;
            end
        end else if (cache_bypass) begin
            // Prefetcher idle during cache bypass mode
            state            <= S_IDLE;
            pending_valid    <= 1'b0;
            pf_hit_pulse     <= 1'b0;
        end else begin
            pf_hit_pulse <= 1'b0;

            // ----------------------------------------------------------------
            // 1. RPT Training Table Update
            // ----------------------------------------------------------------
            if (train_fire) begin
                if (!rpt_valid[train_idx] || (rpt_pc_tag[train_idx] != train_tag)) begin
                    // Cold miss or tag mismatch (PC aliasing): re-initialize entry
                    rpt_valid[train_idx]     <= 1'b1;
                    rpt_pc_tag[train_idx]    <= train_tag;
                    rpt_last_addr[train_idx] <= load_addr;
                    rpt_stride[train_idx]    <= 16'sd0;
                    rpt_conf[train_idx]      <= CONF_INIT;
                end else begin
                    // Valid entry with matching PC tag
                    if (new_stride != 16'sd0) begin
                        if (new_stride == rpt_stride[train_idx]) begin
                            // Stride repeated: increment confidence up to STEADY
                            if (rpt_conf[train_idx] < CONF_STEADY)
                                rpt_conf[train_idx] <= rpt_conf[train_idx] + 2'd1;
                        end else begin
                            // Stride changed: retrain stride, reset confidence to INIT
                            rpt_stride[train_idx] <= new_stride;
                            rpt_conf[train_idx]   <= CONF_INIT;
                        end
                        rpt_last_addr[train_idx] <= load_addr;
                    end
                    // Stride == 0 is ignored (no state update)
                end
            end

            // ----------------------------------------------------------------
            // 2. Pending Prefetch Registration
            // ----------------------------------------------------------------
            if (cand_valid) begin
                pending_valid <= 1'b1;
                pending_addr  <= cand_line_addr;
            end

            // ----------------------------------------------------------------
            // 3. Store Coherence Invalidation
            // ----------------------------------------------------------------
            if (store_valid) begin
                // Invalidate prefetch buffer if store address hits buffered line
                if (pf_valid && (pf_tag == store_addr[ADDR_WIDTH-1:4])) begin
                    pf_valid <= 1'b0;
                end
                // If in-flight prefetch target matches store address, invalidate on arrival
                if (inflight && (inflight_tag == store_addr[ADDR_WIDTH-1:4])) begin
                    inflight_invalid <= 1'b1;
                end
                // If pending prefetch matches store address, cancel pending request
                if (pending_valid && (pending_addr[ADDR_WIDTH-1:4] == store_addr[ADDR_WIDTH-1:4])) begin
                    pending_valid <= 1'b0;
                end
            end

            // ----------------------------------------------------------------
            // 4. Prefetch Buffer Consumption (on L1 Demand Hit)
            // ----------------------------------------------------------------
            if (l1_mem_req && l1_hit_pf_buf) begin
                pf_valid     <= 1'b0; // Line transferred to L1
                pf_hit_pulse <= 1'b1; // Strobe perf profiler
            end

            // ----------------------------------------------------------------
            // 5. Memory Arbitration State Machine
            // ----------------------------------------------------------------
            case (state)
                S_IDLE: begin
                    // In S_IDLE, prefetch requests can be issued if L1 is idle and no demand miss
                    if (!l1_mem_req && l1_idle && pending_valid) begin
                        state            <= S_PREF_WAIT;
                        inflight         <= 1'b1;
                        inflight_tag     <= pending_addr[ADDR_WIDTH-1:4];
                        inflight_invalid <= 1'b0;
                        pending_valid    <= 1'b0;
                    end
                end

                S_PREF_WAIT: begin
                    if (main_mem_ack) begin
                        state    <= S_IDLE;
                        inflight <= 1'b0;

                        // Check if demand miss was waiting for this exact line (merge hit!)
                        if (l1_mem_req && (l1_mem_addr[ADDR_WIDTH-1:4] == inflight_tag) && !l1_mem_we) begin
                            pf_hit_pulse <= 1'b1;
                            pf_valid     <= 1'b0;
                        end else if (!inflight_invalid) begin
                            // Otherwise, store into prefetch buffer
                            pf_valid <= 1'b1;
                            pf_tag   <= inflight_tag;
                            pf_data  <= main_mem_rdata;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // ------------------------------------------------------------------------
    // Combinational Output Multiplexing (Decoupled, zero-loop continuous assignments)
    // ------------------------------------------------------------------------
    wire pref_active = (prefetch_en == 1'b1) && !cache_bypass;

    // Prefetch hit pulse or in-flight merge hit
    wire merge_hit = pref_active && (state == S_PREF_WAIT) && main_mem_ack &&
                     l1_mem_req && (l1_mem_addr[ADDR_WIDTH-1:4] == inflight_tag) && !l1_mem_we;

    wire pf_hit_comb = pref_active && ((l1_mem_req && l1_hit_pf_buf) || merge_hit);
    assign prefetch_hit = pf_hit_comb || pf_hit_pulse;

    // L1 Memory Interface (towards L1 Cache Controller)
    assign l1_mem_ack = (!pref_active) ? main_mem_ack :
                        (l1_hit_pf_buf) ? 1'b1 :
                        merge_hit       ? 1'b1 :
                        (state == S_PREF_WAIT) ? 1'b0 :
                        main_mem_ack;

    assign l1_mem_rdata = (pref_active && l1_hit_pf_buf) ? pf_data : main_mem_rdata;

    // Main Memory Interface (towards main_memory model)
    assign main_mem_req = (!pref_active) ? l1_mem_req :
                          (state == S_PREF_WAIT) ? 1'b1 :
                          (l1_mem_req && l1_hit_pf_buf) ? 1'b0 :
                          l1_mem_req ? 1'b1 :
                          (l1_idle && pending_valid);

    assign main_mem_we  = (!pref_active) ? l1_mem_we :
                          l1_mem_req ? l1_mem_we : 1'b0;

    assign main_mem_addr = (!pref_active) ? l1_mem_addr :
                           (state == S_PREF_WAIT) ? {inflight_tag, 4'b0000} :
                           l1_mem_req ? l1_mem_addr : pending_addr;

    assign main_mem_wdata = l1_mem_wdata;

endmodule
