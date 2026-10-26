`timescale 1ns / 1ps

// ============================================================================
// Module: l1_cache_controller
// Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher
//
// Description:
//   2 KB Direct-Mapped L1 Data Cache Controller with Victim Cache Swap Support.
//   - 128 cache lines, 16-byte block size (4 x 32-bit words).
//   - Byte-level write strobes for SB, SH, SW support.
//   - Write-back policy with dirty bit tracking.
//   - Hardware block-swapping FSM state (VC_SWAP) for 2-cycle Victim Cache hits.
// ============================================================================

module l1_cache_controller #(
    parameter DATA_WIDTH  = 32,
    parameter ADDR_WIDTH  = 32,
    parameter BLOCK_WORDS = 4,    // 4 words = 16 bytes per cache line
    parameter BLOCK_BITS  = 4,    // 16-byte block offset
    parameter INDEX_BITS  = 7     // 128 cache lines (2 KB total data storage)
)(
    input  wire                   clk,
    input  wire                   rst,

    // ------------------------------------------------------------------------
    // CPU Pipeline Interface (Connects to RV32I Hazard Unit & Memory Stage)
    // ------------------------------------------------------------------------
    input  wire                   cpu_req,
    input  wire                   cpu_we,
    input  wire [ADDR_WIDTH-1:0]  cpu_addr,
    input  wire [DATA_WIDTH-1:0]  cpu_wdata,
    input  wire [3:0]             cpu_wmask,
    output reg  [DATA_WIDTH-1:0]  cpu_rdata,
    output reg                    cpu_stall,

    // Hardware Cache-Bypass Switch (TA Requirement / FPGA Switch SW[2])
    input  wire                   cache_bypass,

    // ------------------------------------------------------------------------
    // Performance Profiler Interface (For Archit's Hardware Counters)
    // ------------------------------------------------------------------------
    output wire                   l1_access,
    output wire                   l1_hit,
    output wire                   l1_miss,
    output wire                   vc_hit_o,

    // ------------------------------------------------------------------------
    // Main Memory / Interconnect Interface (128-bit Block Transfers)
    // ------------------------------------------------------------------------
    output reg                    mem_req,
    output reg                    mem_we,
    output reg  [ADDR_WIDTH-1:0]  mem_addr,
    output reg  [BLOCK_WORDS*DATA_WIDTH-1:0] mem_wdata,
    input  wire [BLOCK_WORDS*DATA_WIDTH-1:0] mem_rdata,
    input  wire                   mem_ack,

    // ------------------------------------------------------------------------
    // Victim Cache Bidirectional Interface (Lookup, Eviction Push & Block Swap)
    // ------------------------------------------------------------------------
    output wire [ADDR_WIDTH-1:0]             victim_lookup_addr,
    input  wire                              victim_hit,
    input  wire [BLOCK_WORDS*DATA_WIDTH-1:0] victim_hit_data,
    output reg                               victim_evict_valid,
    output reg                               victim_swap_valid,
    output reg  [ADDR_WIDTH-1:0]             victim_evict_addr,
    output reg  [BLOCK_WORDS*DATA_WIDTH-1:0] victim_evict_data,

    // ------------------------------------------------------------------------
    // Stride Prefetcher Interface (Interface for Archit's Prefetcher in Week 5)
    // ------------------------------------------------------------------------
    output wire                              prefetch_snoop_valid,
    output wire [ADDR_WIDTH-1:0]             prefetch_snoop_addr,
    output wire                              prefetch_snoop_miss,

    input  wire                              prefetch_req,
    input  wire [ADDR_WIDTH-1:0]             prefetch_addr,
    input  wire [BLOCK_WORDS*DATA_WIDTH-1:0] prefetch_data,
    output reg                               prefetch_ack
);

    localparam LINE_WIDTH = BLOCK_WORDS * DATA_WIDTH; // 128 bits
    localparam TAG_BITS   = ADDR_WIDTH - INDEX_BITS - BLOCK_BITS; // 21 bits
    localparam NUM_LINES  = 1 << INDEX_BITS; // 128 lines

    // ------------------------------------------------------------------------
    // FSM States
    // ------------------------------------------------------------------------
    localparam IDLE         = 4'd0;
    localparam WRITE_BACK   = 4'd1;
    localparam WB_WAIT      = 4'd2;
    localparam ALLOCATE     = 4'd3;
    localparam RESP         = 4'd4;
    localparam VC_SWAP      = 4'd5;
    localparam BYPASS_READ  = 4'd6;
    localparam BYPASS_WRITE = 4'd7;
    localparam BYPASS_WB    = 4'd8;

    reg [3:0] state, next_state;

    // ------------------------------------------------------------------------
    // Address Field Decomposition
    // ------------------------------------------------------------------------
    wire [TAG_BITS-1:0]   req_tag      = cpu_addr[ADDR_WIDTH-1 : ADDR_WIDTH-TAG_BITS];
    wire [INDEX_BITS-1:0] req_index    = cpu_addr[ADDR_WIDTH-TAG_BITS-1 : BLOCK_BITS];
    wire [1:0]            req_word_sel = cpu_addr[3:2];

    // Latched request registers during multi-cycle miss penalty
    reg [ADDR_WIDTH-1:0]  latched_addr;
    reg [DATA_WIDTH-1:0]  latched_wdata;
    reg [3:0]             latched_wmask;
    reg                   latched_we;
    reg                   latched_vc_hit;

    wire [TAG_BITS-1:0]   latched_tag      = latched_addr[ADDR_WIDTH-1 : ADDR_WIDTH-TAG_BITS];
    wire [INDEX_BITS-1:0] latched_index    = latched_addr[ADDR_WIDTH-TAG_BITS-1 : BLOCK_BITS];
    wire [1:0]            latched_word_sel = latched_addr[3:2];

    // Prefetch Address Decomposition
    wire [TAG_BITS-1:0]   pref_tag   = prefetch_addr[ADDR_WIDTH-1 : ADDR_WIDTH-TAG_BITS];
    wire [INDEX_BITS-1:0] pref_index = prefetch_addr[ADDR_WIDTH-TAG_BITS-1 : BLOCK_BITS];

    // Address sent to Victim Cache for parallel tag lookup
    assign victim_lookup_addr = (state == IDLE)
                              ? {req_tag, req_index, {BLOCK_BITS{1'b0}}}
                              : {latched_tag, latched_index, {BLOCK_BITS{1'b0}}};

    // ------------------------------------------------------------------------
    // Storage Arrays
    // ------------------------------------------------------------------------
    (* ram_style = "block" *)
    reg [LINE_WIDTH-1:0] data_array [0:NUM_LINES-1];

    reg [TAG_BITS-1:0]   tag_array  [0:NUM_LINES-1];
    reg                  valid_bits [0:NUM_LINES-1];
    reg                  dirty_bits [0:NUM_LINES-1];

    // ------------------------------------------------------------------------
    // Cache Hit / Miss Detection
    // ------------------------------------------------------------------------
    wire line_valid = valid_bits[req_index];
    wire tag_match  = (tag_array[req_index] == req_tag);
    wire cache_hit  = line_valid && tag_match;
    wire cache_miss = cpu_req && !cache_hit;

    // Word Extraction from the 128-bit Cache Line
    wire [LINE_WIDTH-1:0] current_line = data_array[req_index];
    reg  [DATA_WIDTH-1:0] selected_word;
    always @(*) begin
        case (req_word_sel)
            2'b00: selected_word = current_line[31:0];
            2'b01: selected_word = current_line[63:32];
            2'b10: selected_word = current_line[95:64];
            2'b11: selected_word = current_line[127:96];
        endcase
    end

    // Latched word extraction for refill / swap response
    wire [LINE_WIDTH-1:0] latched_line = data_array[latched_index];
    reg  [DATA_WIDTH-1:0] latched_word;
    always @(*) begin
        case (latched_word_sel)
            2'b00: latched_word = latched_line[31:0];
            2'b01: latched_word = latched_line[63:32];
            2'b10: latched_word = latched_line[95:64];
            2'b11: latched_word = latched_line[127:96];
        endcase
    end

    // Performance profiling signals (1-cycle pulses in IDLE, suppressed when bypassed)
    assign l1_access = (state == IDLE) && cpu_req && !cache_bypass;
    assign l1_hit    = (state == IDLE) && cpu_req && !cache_bypass && cache_hit;
    assign l1_miss   = (state == IDLE) && cpu_req && !cache_bypass && !cache_hit;
    assign vc_hit_o  = (state == IDLE) && cpu_req && !cache_bypass && !cache_hit && victim_hit;

    // Stride prefetcher snoop bus (tracks memory access stream to train prefetch tables)
    assign prefetch_snoop_valid = (state == IDLE) && cpu_req && !cache_bypass;
    assign prefetch_snoop_addr  = cpu_addr;
    assign prefetch_snoop_miss  = (state == IDLE) && cpu_req && !cache_bypass && !cache_hit;

    // Registers for cache bypass transactions
    reg [DATA_WIDTH-1:0]  bypass_rdata;
    reg [LINE_WIDTH-1:0]  bypass_wline;

    // Helper: Build a 128-bit line with byte-level write modifications
    function [LINE_WIDTH-1:0] apply_byte_write(
        input [LINE_WIDTH-1:0] line_in,
        input [1:0]            word_idx,
        input [DATA_WIDTH-1:0] wdata,
        input [3:0]            wmask
    );
        reg [DATA_WIDTH-1:0] w0, w1, w2, w3;
        begin
            w0 = line_in[31:0];
            w1 = line_in[63:32];
            w2 = line_in[95:64];
            w3 = line_in[127:96];

            case (word_idx)
                2'b00: begin
                    if (wmask[0]) w0[7:0]   = wdata[7:0];
                    if (wmask[1]) w0[15:8]  = wdata[15:8];
                    if (wmask[2]) w0[23:16] = wdata[23:16];
                    if (wmask[3]) w0[31:24] = wdata[31:24];
                end
                2'b01: begin
                    if (wmask[0]) w1[7:0]   = wdata[7:0];
                    if (wmask[1]) w1[15:8]  = wdata[15:8];
                    if (wmask[2]) w1[23:16] = wdata[23:16];
                    if (wmask[3]) w1[31:24] = wdata[31:24];
                end
                2'b10: begin
                    if (wmask[0]) w2[7:0]   = wdata[7:0];
                    if (wmask[1]) w2[15:8]  = wdata[15:8];
                    if (wmask[2]) w2[23:16] = wdata[23:16];
                    if (wmask[3]) w2[31:24] = wdata[31:24];
                end
                2'b11: begin
                    if (wmask[0]) w3[7:0]   = wdata[7:0];
                    if (wmask[1]) w3[15:8]  = wdata[15:8];
                    if (wmask[2]) w3[23:16] = wdata[23:16];
                    if (wmask[3]) w3[31:24] = wdata[31:24];
                end
            endcase
            apply_byte_write = {w3, w2, w1, w0};
        end
    endfunction

    // ------------------------------------------------------------------------
    // Synchronous data array writes (No async reset -> Infers Distributed LUTRAM)
    always @(posedge clk) begin
        if (state == IDLE && cpu_req && !cache_bypass && cache_hit && cpu_we) begin
            data_array[req_index] <= apply_byte_write(data_array[req_index], req_word_sel, cpu_wdata, cpu_wmask);
        end else if (state == VC_SWAP) begin
            if (latched_we) begin
                data_array[latched_index] <= apply_byte_write(victim_hit_data, latched_word_sel, latched_wdata, latched_wmask);
            end else begin
                data_array[latched_index] <= victim_hit_data;
            end
        end else if (state == ALLOCATE && mem_ack) begin
            if (latched_we) begin
                data_array[latched_index] <= apply_byte_write(mem_rdata, latched_word_sel, latched_wdata, latched_wmask);
            end else begin
                data_array[latched_index] <= mem_rdata;
            end
        end else if (state == IDLE && !cpu_req && prefetch_req) begin
            if (!(valid_bits[pref_index] && dirty_bits[pref_index])) begin
                data_array[pref_index] <= prefetch_data;
            end
        end
    end

    // ------------------------------------------------------------------------
    // FSM Sequential Logic
    // ------------------------------------------------------------------------
    integer j;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state              <= IDLE;
            latched_addr       <= 0;
            latched_wdata      <= 0;
            latched_wmask      <= 0;
            latched_we         <= 0;
            latched_vc_hit     <= 1'b0;
            victim_evict_valid <= 1'b0;
            victim_evict_addr  <= 0;
            victim_evict_data  <= 0;
            prefetch_ack       <= 1'b0;
            bypass_rdata       <= 32'd0;
            bypass_wline       <= 128'd0;
            for (j = 0; j < NUM_LINES; j = j + 1) begin
                valid_bits[j] <= 1'b0;
                dirty_bits[j] <= 1'b0;
                tag_array[j]  <= 0;
            end
        end else begin
            state <= next_state;

            // Default: de-assert 1-cycle eviction push pulse
            victim_evict_valid <= 1'b0;

            // Latch request parameters on L1 miss or bypass
            if (state == IDLE && cpu_req && (cache_bypass || !cache_hit)) begin
                latched_addr   <= cpu_addr;
                latched_wdata  <= cpu_wdata;
                latched_wmask  <= cpu_wmask;
                latched_we     <= cpu_we;
                latched_vc_hit <= victim_hit;

                // Capture displaced L1 block for Victim Cache push or swap (only when not bypassed)
                if (!cache_bypass && valid_bits[req_index]) begin
                    victim_evict_addr <= {tag_array[req_index], req_index, {BLOCK_BITS{1'b0}}};
                    victim_evict_data <= data_array[req_index];
                    // If Victim Cache missed, push evicted block into VC LRU slot immediately.
                    // If Victim Cache hit, VC_SWAP state will atomically swap it instead.
                    if (!victim_hit) begin
                        victim_evict_valid <= 1'b1;
                    end
                end
            end

            // Bypass Read and Write buffering
            if (state == BYPASS_READ && mem_ack) begin
                case (latched_word_sel)
                    2'b00: bypass_rdata <= mem_rdata[31:0];
                    2'b01: bypass_rdata <= mem_rdata[63:32];
                    2'b10: bypass_rdata <= mem_rdata[95:64];
                    2'b11: bypass_rdata <= mem_rdata[127:96];
                endcase
            end else if (state == BYPASS_WRITE && mem_ack) begin
                bypass_wline <= apply_byte_write(mem_rdata, latched_word_sel, latched_wdata, latched_wmask);
            end else if (state == BYPASS_WB && mem_ack) begin
                if (valid_bits[latched_index] && (tag_array[latched_index] == latched_tag)) begin
                    valid_bits[latched_index] <= 1'b0;
                end
            end

            // Tag & Valid/Dirty Status Updates (data_array updated in synchronous RAM block)
            if (state == IDLE && cpu_req && !cache_bypass && cache_hit && cpu_we) begin
                // 1. L1 Write Hit
                dirty_bits[req_index] <= 1'b1;
            end else if (state == VC_SWAP) begin
                // 2. Victim Cache Hit Refill (1-Cycle Hardware Swap)
                valid_bits[latched_index] <= 1'b1;
                tag_array[latched_index]  <= latched_tag;
                dirty_bits[latched_index] <= latched_we;
            end else if (state == ALLOCATE && mem_ack) begin
                // 3. Main Memory Miss Refill
                valid_bits[latched_index] <= 1'b1;
                tag_array[latched_index]  <= latched_tag;
                dirty_bits[latched_index] <= latched_we;
            end else if (state == IDLE && !cpu_req && prefetch_req) begin
                // 4. Opportunistic Prefetch Refill when pipeline is idle
                if (!(valid_bits[pref_index] && dirty_bits[pref_index])) begin
                    tag_array[pref_index]  <= pref_tag;
                    valid_bits[pref_index] <= 1'b1;
                    dirty_bits[pref_index] <= 1'b0;
                    prefetch_ack           <= 1'b1;
                end
            end

            // Auto-clear prefetch_ack
            if (!(state == IDLE && !cpu_req && prefetch_req)) begin
                prefetch_ack <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------------
    // FSM Combinational Logic
    // ------------------------------------------------------------------------
    always @(*) begin
        next_state        = state;
        cpu_stall         = 1'b0;
        mem_req           = 1'b0;
        mem_we            = 1'b0;
        mem_addr          = {ADDR_WIDTH{1'b0}};
        mem_wdata         = {LINE_WIDTH{1'b0}};
        cpu_rdata         = selected_word;
        victim_swap_valid = 1'b0;

        case (state)
            IDLE: begin
                if (cpu_req) begin
                    if (cache_bypass) begin
                        cpu_stall = 1'b1; // Stalled for uncached memory access
                        if (valid_bits[req_index] && dirty_bits[req_index]) begin
                            next_state = WRITE_BACK;
                        end else if (cpu_we) begin
                            next_state = BYPASS_WRITE;
                        end else begin
                            next_state = BYPASS_READ;
                        end
                    end else begin
                        if (cache_hit) begin
                            cpu_stall  = 1'b0; // Zero-stall L1 hit
                            cpu_rdata  = selected_word;
                            next_state = IDLE;
                        end else begin
                            cpu_stall = 1'b1;  // L1 miss penalty begins
                            if (valid_bits[req_index] && dirty_bits[req_index]) begin
                                // Write back dirty L1 line first so VC always stays clean/coherent
                                next_state = WRITE_BACK;
                            end else if (victim_hit) begin
                                // Fast 1-cycle swap with Victim Cache (skips Main Memory!)
                                next_state = VC_SWAP;
                            end else begin
                                // Fetch from Main Memory
                                next_state = ALLOCATE;
                            end
                        end
                    end
                end
            end

            WRITE_BACK: begin
                cpu_stall = 1'b1;
                mem_req   = 1'b1;
                mem_we    = 1'b1;
                mem_addr  = {tag_array[latched_index], latched_index, {BLOCK_BITS{1'b0}}};
                mem_wdata = data_array[latched_index];

                if (mem_ack) begin
                    next_state = WB_WAIT;
                end
            end

            WB_WAIT: begin
                cpu_stall = 1'b1;
                mem_req   = 1'b0;
                mem_we    = 1'b0;
                if (cache_bypass) begin
                    next_state = latched_we ? BYPASS_WRITE : BYPASS_READ;
                end else if (latched_vc_hit) begin
                    next_state = VC_SWAP;
                end else begin
                    next_state = ALLOCATE;
                end
            end

            VC_SWAP: begin
                cpu_stall         = 1'b1;
                victim_swap_valid = 1'b1;
                next_state        = RESP;
            end

            ALLOCATE: begin
                cpu_stall = 1'b1;
                mem_req   = 1'b1;
                mem_we    = 1'b0;
                mem_addr  = {latched_tag, latched_index, {BLOCK_BITS{1'b0}}};

                if (mem_ack) begin
                    next_state = RESP;
                end
            end

            BYPASS_READ: begin
                cpu_stall = 1'b1;
                mem_req   = 1'b1;
                mem_we    = 1'b0;
                mem_addr  = {latched_tag, latched_index, {BLOCK_BITS{1'b0}}};

                if (mem_ack) begin
                    next_state = RESP;
                end
            end

            BYPASS_WRITE: begin
                cpu_stall = 1'b1;
                mem_req   = 1'b1;
                mem_we    = 1'b0;
                mem_addr  = {latched_tag, latched_index, {BLOCK_BITS{1'b0}}};

                if (mem_ack) begin
                    next_state = BYPASS_WB;
                end
            end

            BYPASS_WB: begin
                cpu_stall = 1'b1;
                mem_req   = 1'b1;
                mem_we    = 1'b1;
                mem_addr  = {latched_tag, latched_index, {BLOCK_BITS{1'b0}}};
                mem_wdata = bypass_wline;

                if (mem_ack) begin
                    next_state = RESP;
                end
            end

            RESP: begin
                cpu_stall  = 1'b0;
                cpu_rdata  = cache_bypass ? bypass_rdata : latched_word;
                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

endmodule