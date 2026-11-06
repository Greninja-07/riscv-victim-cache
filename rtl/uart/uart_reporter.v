`timescale 1ns / 1ps

// ============================================================================
// Module: uart_reporter
// Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher
// Author: Group 14
//
// Description:
//   Serial Telemetry Engine that packs 6 hardware performance counters and
//   the 16 FPGA switch states into a 28-byte frame and streams it over UART
//   at 115200 baud to the live web dashboard.
//
// Frame Format (28 Bytes):
//   [0]:      0xAA (Sync Header 1)
//   [1]:      0x55 (Sync Header 2)
//   [2..5]:   total_cycles  [31:0] (Big-endian)
//   [6..9]:   stall_cycles  [31:0]
//   [10..13]: l1_accesses   [31:0]
//   [14..17]: l1_misses     [31:0]
//   [18..21]: victim_hits   [31:0]
//   [22..25]: prefetch_hits [31:0]
//   [26..27]: sw            [15:0]
// ============================================================================

module uart_reporter #(
    parameter CLK_FREQ_HZ = 100_000_000,
    parameter REPORT_INTERVAL_CYCLES = 5_000_000 // 20 Hz (every 50 ms)
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] total_cycles,
    input  wire [31:0] stall_cycles,
    input  wire [31:0] l1_accesses,
    input  wire [31:0] l1_misses,
    input  wire [31:0] victim_hits,
    input  wire [31:0] prefetch_hits,
    input  wire [15:0] sw,
    output wire        uart_tx_pin
);

    // Periodic timer trigger
    reg [23:0] timer_cnt = 24'd0;
    reg        trigger_send = 1'b0;
    reg [15:0] sw_prev = 16'd0;

    // Buffer to hold captured snapshot while transmitting
    reg [7:0] packet [0:27];
    reg [4:0] byte_idx = 5'd0;
    reg       transmitting = 1'b0;

    // UART TX handshake
    reg  [7:0] tx_data = 8'd0;
    reg        tx_valid = 1'b0;
    wire       tx_ready;

    uart_tx #(
        .CLKS_PER_BIT(868) // 100 MHz / 115200
    ) u_tx (
        .clk     (clk),
        .rst     (rst),
        .tx_data (tx_data),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .tx_pin  (uart_tx_pin)
    );

    // Trigger on timer OR immediate switch toggle
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            timer_cnt    <= 24'd0;
            trigger_send <= 1'b0;
            sw_prev      <= 16'd0;
        end else begin
            sw_prev <= sw;
            if (sw != sw_prev) begin
                trigger_send <= 1'b1;
                timer_cnt    <= 24'd0;
            end else if (timer_cnt >= REPORT_INTERVAL_CYCLES - 1) begin
                timer_cnt    <= 24'd0;
                trigger_send <= 1'b1;
            end else begin
                timer_cnt    <= timer_cnt + 1'b1;
                trigger_send <= 1'b0;
            end
        end
    end

    // Packet Sequencer FSM
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            transmitting <= 1'b0;
            byte_idx     <= 5'd0;
            tx_valid     <= 1'b0;
            tx_data      <= 8'd0;
        end else begin
            if (!transmitting) begin
                if (trigger_send && tx_ready) begin
                    // Latch packet snapshot
                    packet[0]  <= 8'hAA;
                    packet[1]  <= 8'h55;

                    packet[2]  <= total_cycles[31:24];
                    packet[3]  <= total_cycles[23:16];
                    packet[4]  <= total_cycles[15:8];
                    packet[5]  <= total_cycles[7:0];

                    packet[6]  <= stall_cycles[31:24];
                    packet[7]  <= stall_cycles[23:16];
                    packet[8]  <= stall_cycles[15:8];
                    packet[9]  <= stall_cycles[7:0];

                    packet[10] <= l1_accesses[31:24];
                    packet[11] <= l1_accesses[23:16];
                    packet[12] <= l1_accesses[15:8];
                    packet[13] <= l1_accesses[7:0];

                    packet[14] <= l1_misses[31:24];
                    packet[15] <= l1_misses[23:16];
                    packet[16] <= l1_misses[15:8];
                    packet[17] <= l1_misses[7:0];

                    packet[18] <= victim_hits[31:24];
                    packet[19] <= victim_hits[23:16];
                    packet[20] <= victim_hits[15:8];
                    packet[21] <= victim_hits[7:0];

                    packet[22] <= prefetch_hits[31:24];
                    packet[23] <= prefetch_hits[23:16];
                    packet[24] <= prefetch_hits[15:8];
                    packet[25] <= prefetch_hits[7:0];

                    packet[26] <= sw[15:8];
                    packet[27] <= sw[7:0];

                    byte_idx     <= 5'd0;
                    transmitting <= 1'b1;
                    tx_data      <= 8'hAA;
                    tx_valid     <= 1'b1;
                end else begin
                    tx_valid <= 1'b0;
                end
            end else begin
                // While transmitting packet bytes
                if (tx_valid && tx_ready) begin
                    tx_valid <= 1'b0;
                end else if (!tx_valid && tx_ready) begin
                    if (byte_idx < 5'd27) begin
                        byte_idx <= byte_idx + 1'b1;
                        tx_data  <= packet[byte_idx + 1'b1];
                        tx_valid <= 1'b1;
                    end else begin
                        transmitting <= 1'b0;
                        byte_idx     <= 5'd0;
                    end
                end
            end
        end
    end

endmodule
