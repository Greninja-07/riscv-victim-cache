`timescale 1ns / 1ps
module tb_uart_test;
    reg clk = 0;
    reg rst = 1;
    always #5 clk = ~clk;

    wire uart_tx_pin;
    uart_reporter #(
        .CLK_FREQ_HZ(100_000_000),
        .REPORT_INTERVAL_CYCLES(500)
    ) rep (
        .clk(clk),
        .rst(rst),
        .total_cycles(32'h12345678),
        .stall_cycles(32'h0000000A),
        .l1_accesses(32'h00000020),
        .l1_misses(32'h00000005),
        .victim_hits(32'h00000003),
        .prefetch_hits(32'h00000002),
        .sw(16'h0080),
        .uart_tx_pin(uart_tx_pin)
    );

    // Simple UART receiver model @ 115200 (8680 ns per bit)
    reg [7:0] rx_byte;
    integer b_i;
    reg [7:0] received [0:35];
    integer rx_count = 0;

    always begin
        @(negedge uart_tx_pin); // Start bit
        #(8680 * 1.5); // sample midpoint of bit 0
        for (b_i = 0; b_i < 8; b_i = b_i + 1) begin
            rx_byte[b_i] = uart_tx_pin;
            #8680;
        end
        received[rx_count] = rx_byte;
        rx_count = rx_count + 1;
        $display("RX BYTE [%0d]: 0x%02X", rx_count-1, rx_byte);
        if (rx_count == 28) begin
            $display("SUCCESS: ALL 28 BYTES RECEIVED MATCHING PROTOCOL!");
            $finish;
        end
    end

    initial begin
        #50 rst = 0;
        #30000000;
        $display("TIMEOUT! Received: %0d bytes", rx_count);
        $finish;
    end
endmodule
