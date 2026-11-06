`timescale 1ns / 1ps

// ============================================================================
// Module: uart_tx
// Description:
//   Standard 8-N-1 UART Transmitter.
//   Default baud: 115200 @ 100 MHz clock (CLKS_PER_BIT = 868).
// ============================================================================

module uart_tx #(
    parameter CLKS_PER_BIT = 868 // 100 MHz / 115200 baud = ~868
)(
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] tx_data,
    input  wire       tx_valid,
    output reg        tx_ready,
    output reg        tx_pin
);

    localparam STATE_IDLE  = 2'd0;
    localparam STATE_START = 2'd1;
    localparam STATE_DATA  = 2'd2;
    localparam STATE_STOP  = 2'd3;

    reg [1:0]  state;
    reg [15:0] clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shifter;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state    <= STATE_IDLE;
            clk_cnt  <= 16'd0;
            bit_idx  <= 3'd0;
            shifter  <= 8'd0;
            tx_ready <= 1'b1;
            tx_pin   <= 1'b1; // Idle high
        end else begin
            case (state)
                STATE_IDLE: begin
                    tx_pin   <= 1'b1;
                    clk_cnt  <= 16'd0;
                    bit_idx  <= 3'd0;
                    if (tx_valid && tx_ready) begin
                        shifter  <= tx_data;
                        tx_ready <= 1'b0;
                        tx_pin   <= 1'b0; // Start bit
                        state    <= STATE_START;
                    end else begin
                        tx_ready <= 1'b1;
                    end
                end

                STATE_START: begin
                    if (clk_cnt < CLKS_PER_BIT - 1) begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        clk_cnt <= 16'd0;
                        tx_pin  <= shifter[0];
                        state   <= STATE_DATA;
                    end
                end

                STATE_DATA: begin
                    if (clk_cnt < CLKS_PER_BIT - 1) begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        clk_cnt <= 16'd0;
                        if (bit_idx < 3'd7) begin
                            bit_idx <= bit_idx + 1'b1;
                            shifter <= {1'b0, shifter[7:1]};
                            tx_pin  <= shifter[1];
                        end else begin
                            bit_idx <= 3'd0;
                            tx_pin  <= 1'b1; // Stop bit
                            state   <= STATE_STOP;
                        end
                    end
                end

                STATE_STOP: begin
                    if (clk_cnt < CLKS_PER_BIT - 1) begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        clk_cnt  <= 16'd0;
                        tx_ready <= 1'b1;
                        state    <= STATE_IDLE;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
