`timescale 1ns / 1ps

// ============================================================================
// Module: l1_cache_controller
// Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher
//
// Description:
//   2 KB Direct-Mapped L1 Data Cache Controller.
//   - 128 cache lines, 16-byte block size (4 x 32-bit words).
//   - Byte-level write strobes for SB, SH, SW support.
//   - Write-back policy with dirty bit tracking.
//   - Block-level memory interface (128-bit lines) with eviction signaling.
//   - Zero-stall hit path for optimal pipeline throughput.
//   - Synthesizable FPGA Block RAM (BRAM) inference style.
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

    // ------------------------------------------------------------------------
    // Performance Profiler Interface (For Archit's Hardware Counters)
    // ------------------------------------------------------------------------
    output wire                   l1_access,
    output wire                   l1_hit,
    output wire                   l1_miss,

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
    // Victim Cache Eviction Bus (Interface for Soham's Victim Cache in Week 4)
    // ------------------------------------------------------------------------
    output reg                    victim_evict_valid,
    output reg  [ADDR_WIDTH-1:0]  victim_evict_addr,
    output reg  [BLOCK_WORDS*DATA_WIDTH-1:0] victim_evict_data
);

    localparam LINE_WIDTH = BLOCK_WORDS * DATA_WIDTH; // 128 bits
    localparam TAG_BITS   = ADDR_WIDTH - INDEX_BITS - BLOCK_BITS; // 32 - 7 - 4 = 21 bits
    localparam NUM_LINES  = 1 << INDEX_BITS; // 128 lines

    // ------------------------------------------------------------------------
    // FSM States
    // ------------------------------------------------------------------------
    localparam IDLE       = 3'b000;
    localparam WRITE_BACK = 3'b001;
    localparam WB_WAIT    = 3'b010;
    localparam ALLOCATE   = 3'b011;
    localparam RESP       = 3'b100;

    reg [2:0] state, next_state;

    // ------------------------------------------------------------------------
    // Address Field Decomposition
    // ------------------------------------------------------------------------
    // [31:11] = Tag (21 bits)
    // [10:4]  = Index (7 bits)
    // [3:2]   = Word Offset (2 bits)
    // [1:0]   = Byte Offset (2 bits)
    wire [TAG_BITS-1:0]   req_tag      = cpu_addr[ADDR_WIDTH-1 : ADDR_WIDTH-TAG_BITS];
    wire [INDEX_BITS-1:0] req_index    = cpu_addr[ADDR_WIDTH-TAG_BITS-1 : BLOCK_BITS];
    wire [1:0]            req_word_sel = cpu_addr[3:2];

    // Latched request registers during multi-cycle miss penalty
    reg [ADDR_WIDTH-1:0]  latched_addr;
    reg [DATA_WIDTH-1:0]  latched_wdata;
    reg [3:0]             latched_wmask;
    reg                   latched_we;

    wire [TAG_BITS-1:0]   latched_tag      = latched_addr[ADDR_WIDTH-1 : ADDR_WIDTH-TAG_BITS];
    wire [INDEX_BITS-1:0] latched_index    = latched_addr[ADDR_WIDTH-TAG_BITS-1 : BLOCK_BITS];
    wire [1:0]            latched_word_sel = latched_addr[3:2];

    // ------------------------------------------------------------------------
    // Storage Arrays (Synthesizable FPGA BRAM inference for Data Array)
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

    // Latched word extraction for refill response
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

    // Performance profiling signals
    assign l1_access = (state == IDLE) && cpu_req;
    assign l1_hit    = (state == IDLE) && cpu_req && cache_hit;
    assign l1_miss   = (state == IDLE) && cpu_req && !cache_hit;

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
            victim_evict_valid <= 0;
            victim_evict_addr  <= 0;
            victim_evict_data  <= 0;
            for (j = 0; j < NUM_LINES; j = j + 1) begin
                valid_bits[j] <= 1'b0;
                dirty_bits[j] <= 1'b0;
                tag_array[j]  <= 0;
            end
        end else begin
            state <= next_state;

            // Latch request parameters on cold / conflict miss
            if (state == IDLE && cpu_req && !cache_hit) begin
                latched_addr  <= cpu_addr;
                latched_wdata <= cpu_wdata;
                latched_wmask <= cpu_wmask;
                latched_we    <= cpu_we;

                // If existing line is dirty, capture eviction info for victim cache
                // Pulse victim_evict_valid for 1 cycle on ANY valid line eviction (clean or dirty)
                if (state == IDLE && cpu_req && !cache_hit && valid_bits[req_index]) begin
                        victim_evict_valid <= 1'b1;
                        victim_evict_addr  <= {tag_array[req_index], req_index, {BLOCK_BITS{1'b0}}};
                        victim_evict_data  <= data_array[req_index];
                end else begin
                    victim_evict_valid <= 1'b0;
                end
            end else if (state == WRITE_BACK && mem_ack) begin
                victim_evict_valid <= 1'b0;
            end

            // Cache Data & Tag Updates
            if (state == IDLE && cpu_req && cache_hit && cpu_we) begin
                // Hit Store: Update word with byte mask and mark line dirty
                data_array[req_index] <= apply_byte_write(data_array[req_index], req_word_sel, cpu_wdata, cpu_wmask);
                dirty_bits[req_index] <= 1'b1;
            end else if (state == ALLOCATE && mem_ack) begin
                // Miss Refill: Install fetched block from memory into cache line
                valid_bits[latched_index] <= 1'b1;
                tag_array[latched_index]  <= latched_tag;

                if (latched_we) begin
                    // Store Miss: Merge store data into fetched line and mark dirty
                    data_array[latched_index] <= apply_byte_write(mem_rdata, latched_word_sel, latched_wdata, latched_wmask);
                    dirty_bits[latched_index] <= 1'b1;
                end else begin
                    // Load Miss: Write pristine memory block and mark clean
                    data_array[latched_index] <= mem_rdata;
                    dirty_bits[latched_index] <= 1'b0;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // FSM Combinational Logic
    // ------------------------------------------------------------------------
    always @(*) begin
        next_state = state;
        cpu_stall  = 1'b0;
        mem_req    = 1'b0;
        mem_we     = 1'b0;
        mem_addr   = {ADDR_WIDTH{1'b0}};
        mem_wdata  = {LINE_WIDTH{1'b0}};
        cpu_rdata  = selected_word;

        case (state)
            IDLE: begin
                if (cpu_req) begin
                    if (cache_hit) begin
                        cpu_stall = 1'b0; // Zero-stall hit
                        cpu_rdata = selected_word;
                        next_state = IDLE;
                    end else begin
                        cpu_stall = 1'b1; // Miss penalty begins
                        if (valid_bits[req_index] && dirty_bits[req_index]) begin
                            next_state = WRITE_BACK;
                        end else begin
                            next_state = ALLOCATE;
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
                next_state = ALLOCATE;
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

            RESP: begin
                // Hold stall low for 1 cycle to let CPU latch rdata/complete cycle
                cpu_stall = 1'b0;
                cpu_rdata = latched_word;
                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

endmodule