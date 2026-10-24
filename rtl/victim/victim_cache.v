`timescale 1ns / 1ps

// ============================================================================
// Module: victim_cache
// Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher
//
// Description:
//   4-Entry Fully-Associative Victim Cache with True LRU Replacement.
//   - Parallel 28-bit full block address comparators (addr[31:4]).
//   - Combinational lookup for zero-delay L1 miss interception.
//   - Supports 1-cycle eviction push (on L1+VC miss) and 1-cycle in-place
//     atomic block swap (on L1 miss + VC hit).
// ============================================================================

module victim_cache #(
    parameter DATA_WIDTH  = 32,
    parameter ADDR_WIDTH  = 32,
    parameter BLOCK_WORDS = 4,
    parameter BLOCK_BITS  = 4,
    parameter NUM_ENTRIES = 4
)(
    input  wire                              clk,
    input  wire                              rst,

    // ------------------------------------------------------------------------
    // Combinational Lookup Interface (From L1 Cache Controller)
    // ------------------------------------------------------------------------
    input  wire [ADDR_WIDTH-1:0]             lookup_addr,
    output reg                               vc_hit,
    output reg  [BLOCK_WORDS*DATA_WIDTH-1:0] vc_hit_data,

    // ------------------------------------------------------------------------
    // Eviction & Swap Interface (From L1 Cache Controller)
    // ------------------------------------------------------------------------
    input  wire                              evict_valid, // Insert into LRU slot
    input  wire                              swap_valid,  // Swap into hitting slot
    input  wire [ADDR_WIDTH-1:0]             evict_addr,
    input  wire [BLOCK_WORDS*DATA_WIDTH-1:0] evict_data
);

    localparam LINE_WIDTH    = BLOCK_WORDS * DATA_WIDTH; // 128 bits
    localparam FULL_TAG_BITS = ADDR_WIDTH - BLOCK_BITS;  // 28 bits (addr[31:4])

    // ------------------------------------------------------------------------
    // 4-Entry Fully-Associative Storage Arrays + True LRU Age Counters
    // lru_age: 2'd0 = Most Recently Used (MRU), 2'd3 = Least Recently Used (LRU)
    // ------------------------------------------------------------------------
    reg [LINE_WIDTH-1:0]    data_array [0:NUM_ENTRIES-1];
    reg [FULL_TAG_BITS-1:0] tag_array  [0:NUM_ENTRIES-1];
    reg                     valid_bits [0:NUM_ENTRIES-1];
    reg [1:0]               lru_age    [0:NUM_ENTRIES-1];

    wire [FULL_TAG_BITS-1:0] lookup_tag = lookup_addr[ADDR_WIDTH-1 : BLOCK_BITS];
    wire [FULL_TAG_BITS-1:0] evict_tag  = evict_addr[ADDR_WIDTH-1 : BLOCK_BITS];

    // ------------------------------------------------------------------------
    // Parallel Fully-Associative Tag Comparison (Combinational)
    // ------------------------------------------------------------------------
    reg [1:0] hit_idx;
    reg [1:0] lru_idx;
    reg       dup_match;
    reg [1:0] dup_idx;
    integer i;

    always @(*) begin
        vc_hit      = 1'b0;
        vc_hit_data = {LINE_WIDTH{1'b0}};
        hit_idx     = 2'd0;
        lru_idx     = 2'd0;
        dup_match   = 1'b0;
        dup_idx     = 2'd0;

        for (i = 0; i < NUM_ENTRIES; i = i + 1) begin
            // 1. Check if lookup_addr hits in any valid entry
            if (valid_bits[i] && (tag_array[i] == lookup_tag)) begin
                vc_hit      = 1'b1;
                vc_hit_data = data_array[i];
                hit_idx     = i[1:0];
            end

            // 2. Identify the Least Recently Used entry (age == 3)
            if (lru_age[i] == 2'd3) begin
                lru_idx = i[1:0];
            end

            // 3. Safeguard: check if evict_addr already exists in VC
            if (valid_bits[i] && (tag_array[i] == evict_tag)) begin
                dup_match = 1'b1;
                dup_idx   = i[1:0];
            end
        end
    end

    // Target slot for normal eviction: overwrite existing match if present, else LRU slot
    wire [1:0] evict_target_idx = dup_match ? dup_idx : lru_idx;
    wire [1:0] evict_old_age    = lru_age[evict_target_idx];
    wire [1:0] swap_old_age     = lru_age[hit_idx];

    // ------------------------------------------------------------------------
    // Sequential Update Logic (Eviction Push, Block Swap, and True LRU Aging)
    // ------------------------------------------------------------------------
    integer k;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (k = 0; k < NUM_ENTRIES; k = k + 1) begin
                valid_bits[k] <= 1'b0;
                tag_array[k]  <= {FULL_TAG_BITS{1'b0}};
                data_array[k] <= {LINE_WIDTH{1'b0}};
                lru_age[k]    <= k[1:0]; // Strict initial permutation: 0, 1, 2, 3
            end
        end else if (swap_valid && vc_hit) begin
            // Atomic Block Swap: Replace hitting VC entry with displaced L1 block
            valid_bits[hit_idx] <= 1'b1;
            tag_array[hit_idx]  <= evict_tag;
            data_array[hit_idx] <= evict_data;

            // Update True LRU ages: hit_idx becomes MRU (0)
            for (k = 0; k < NUM_ENTRIES; k = k + 1) begin
                if (k[1:0] == hit_idx)
                    lru_age[k] <= 2'd0;
                else if (lru_age[k] < swap_old_age)
                    lru_age[k] <= lru_age[k] + 2'd1;
            end
        end else if (evict_valid) begin
            // Normal L1 Eviction: Insert displaced L1 block into LRU entry
            valid_bits[evict_target_idx] <= 1'b1;
            tag_array[evict_target_idx]  <= evict_tag;
            data_array[evict_target_idx] <= evict_data;

            // Update True LRU ages: evict_target_idx becomes MRU (0)
            for (k = 0; k < NUM_ENTRIES; k = k + 1) begin
                if (k[1:0] == evict_target_idx)
                    lru_age[k] <= 2'd0;
                else if (lru_age[k] < evict_old_age)
                    lru_age[k] <= lru_age[k] + 2'd1;
            end
        end
    end

endmodule