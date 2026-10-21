`timescale 1ns / 1ps

// ============================================================================
// Module: main_memory
// Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher
// Author: Abhishek Kumar (Group 14)
//
// Description:
//   Configurable Latency Main Memory Model for Simulation and FPGA Emulation.
//   - Physical storage remains synthesizable BRAM.
//   - Wrapped in an FSM that delays response by N cycles to model off-chip DRAM.
//   - N is runtime-selectable via board switches (SW[1:0]):
//       2'b00 : N = 1   cycle  (Baseline: cache brings negligible benefit)
//       2'b01 : N = 10  cycles (L2-like latency, moderate miss penalty)
//       2'b10 : N = 100 cycles (Realistic DRAM latency, significant cache benefit)
//       2'b11 : N = 200 cycles (Worst-case stall, max prefetch/victim benefit)
//   - 16-byte (128-bit) block transfers matching L1 cache lines.
//   - Robust request/acknowledge handshake protocol.
// ============================================================================

module main_memory #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 128,      // 16-byte (4 words) block width
    parameter MEM_BYTES  = 16384,
    parameter MEM_DEPTH  = MEM_BYTES / 16, // 16-byte blocks
    parameter LATENCY    = 10,       // Default fallback latency
    parameter INIT_FILE  = ""        // Optional hex init file
)(
    input  wire                  clk,
    input  wire                  rst,

    // Runtime Latency Selection (Connects to FPGA Board Switches SW[1:0])
    input  wire [1:0]            latency_sel,

    // Cache Interconnect Handshake
    input  wire                  mem_req,
    input  wire                  mem_we,
    input  wire [ADDR_WIDTH-1:0] mem_addr,
    input  wire [DATA_WIDTH-1:0] mem_wdata,
    output reg  [DATA_WIDTH-1:0] mem_rdata,
    output reg                   mem_ack
);

    // Block-aligned memory array (BRAM)
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] storage [0:MEM_DEPTH-1];

    // FSM States
    localparam S_IDLE = 1'b0;
    localparam S_BUSY = 1'b1;

    reg state;
    reg [7:0] counter;
    reg [ADDR_WIDTH-1:0] latched_addr;
    reg [DATA_WIDTH-1:0] latched_wdata;
    reg latched_we;

    wire [$clog2(MEM_DEPTH)-1:0] block_idx = latched_addr[$clog2(MEM_BYTES)-1:4]; // 16-byte block index

    // Dynamic latency decoding from board switches
    reg [7:0] active_latency;
    always @(*) begin
        case (latency_sel)
            2'b00: active_latency = 8'd1;   // 1 cycle   (baseline, zero cache benefit)
            2'b01: active_latency = 8'd10;  // 10 cycles  (L2-like, moderate miss penalty)
            2'b10: active_latency = 8'd100; // 100 cycles (realistic DRAM latency)
            2'b11: active_latency = 8'd200; // 200 cycles (worst-case stall)
            default: active_latency = LATENCY;
        endcase
    end

    // =========================================================================
    // INIT_FILE format:
    // One 128-bit block per line in hexadecimal:
    //   {word3, word2, word1, word0} (32 hex characters per line).
    //   word0 is at the lowest byte address (offset +0), and word3 is at offset +12.
    // =========================================================================
    integer i;
    reg [31:0] val0, val1, val2, val3;
    initial begin
        // Initialize memory with predictable test patterns
        for (i = 0; i < MEM_DEPTH; i = i + 1) begin
            val3 = 32'h11110000 + (i * 16) + 12;
            val2 = 32'h22220000 + (i * 16) + 8;
            val1 = 32'h33330000 + (i * 16) + 4;
            val0 = 32'h44440000 + (i * 16);
            storage[i] = {val3, val2, val1, val0};
        end
        // Specific well-known block patterns for unit testing
        storage[0] = {32'hCAFE0003, 32'hCAFE0002, 32'hCAFE0001, 32'hCAFE0000};
        storage[1] = {32'hBEEF0003, 32'hBEEF0002, 32'hBEEF0001, 32'hBEEF0000};

        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, storage);
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state         <= S_IDLE;
            counter       <= 0;
            mem_ack       <= 0;
            mem_rdata     <= 0;
            latched_addr  <= 0;
            latched_wdata <= 0;
            latched_we    <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    mem_ack <= 0;
                    if (mem_req && !mem_ack) begin
                        latched_addr  <= mem_addr;
                        latched_wdata <= mem_wdata;
                        latched_we    <= mem_we;

                        if (active_latency <= 1) begin
                            // Fast 1-cycle acknowledgment (N = 1 baseline)
                            mem_ack <= 1'b1;
                            if (mem_we) begin
                                storage[mem_addr[$clog2(MEM_BYTES)-1:4]] <= mem_wdata;
                            end else begin
                                mem_rdata <= storage[mem_addr[$clog2(MEM_BYTES)-1:4]];
                            end
                        end else begin
                            counter <= active_latency - 1;
                            state   <= S_BUSY;
                        end
                    end
                end

                S_BUSY: begin
                    if (counter == 1) begin
                        mem_ack <= 1'b1;
                        state   <= S_IDLE;
                        if (latched_we) begin
                            storage[block_idx] <= latched_wdata;
                        end else begin
                            mem_rdata <= storage[block_idx];
                        end
                    end else begin
                        counter <= counter - 1;
                    end
                end
            endcase
        end
    end

endmodule
