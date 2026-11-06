`timescale 1ns / 1ps

// ============================================================================
// Module: top_fpga
// Project: RV32I Memory Hierarchy Enhancement with Victim Cache & Prefetcher
// Target: Digilent Nexys A7-100T (Artix-7 XC7A100T-1CSG324C)
// Author: Abhishek Kumar & Team (Group 14)
//
// Description:
//   Top-level FPGA integration for the Week 3 Demonstration Milestone:
//   - RV32IM 3-stage Pipelined Processor Core (pipe.v)
//   - 16 KB Synchronous Instruction Memory BRAM (instr_mem)
//   - Memory Subsystem (mem_subsystem.v):
//       * 2 KB Direct-Mapped L1 Data Cache (l1_cache_controller.v)
//       * Configurable Latency Main Memory BRAM (main_memory.v)
//       * Hardware Cache-Bypass Mode (SW[2])
//       * Runtime Selectable Latency (SW[1:0]: N = 1, 10, 100, 200 cycles)
//   - Hardware Performance Profiler (perf_profiler.v):
//       * 6 saturating 32-bit hardware event counters
//       * Sticky done-freeze capture
//       * Multiplexed 8-digit 7-segment hex display
//       * Slide switch counter selector (SW[5:3])
// ============================================================================

module top_fpga #(
    parameter IMEMSIZE   = 16384,
    parameter DMEMSIZE   = 16384,
    parameter IMEM_HEX   = "imem.hex",
    parameter MEM128_HEX = "mem128.hex"
)(
    input  wire        clk,          // 100 MHz oscillator (pin E3)
    input  wire        reset,        // Active-high push button BTNC (pin N17)
    input  wire [15:0] sw,           // 16 slide switches

    output wire [15:0] led,          // 16 user LEDs
    output wire [6:0]  seg,          // 7-segment active-low cathodes
    output wire [7:0]  an,           // 8-digit active-low anodes
    output wire        dp,           // Decimal point cathode
    output wire        uart_tx       // USB-UART Serial TX pin (D4)
);

    // ------------------------------------------------------------------------
    // Switch Mapping
    // ------------------------------------------------------------------------
    // SW[1:0] : Memory Latency selection (00: N=1, 01: N=10, 10: N=100, 11: N=200)
    // SW[2]   : Hardware Cache Bypass (0 = L1 Cache Enabled, 1 = Bypassed/Uncached)
    // SW[5:3] : Performance Counter Display Selector on 7-Segment Display:
    //             000: Total Cycles
    //             001: Memory Stall Cycles
    //             010: L1 Cache Accesses
    //             011: L1 Cache Misses
    //             100: Victim Cache Hits
    //             101: Prefetch Hits
    //             110: Operation Result (Selected by SW[10:9])
    // SW[6]   : Clock mode (0 = 50 MHz fast CPU execution, 1 = 1 Hz human slow clock)
    // SW[7]   : Victim Cache Enable (0 = Disabled, 1 = Enabled)
    // SW[8]   : Prefetcher Enable toggle (0 = Disabled, 1 = Enabled)
    // SW[11:9]: Operation Result Selector (when SW[5:3] = 110):
    //             000: Op 0 Result (Matrix Inverse * B)
    //             001: Op 1 Result (Vector Dot Product)
    //             010: Op 2 Result (Array Accumulation)
    //             011: Op 3 Result (Strided Transpose Sum)
    //             100: Grand Total Checksum
    //             101: Program Done Flag
    // SW[12]   : Dual Split-Screen Display Mode:
    //              0 = Standard 32-bit single metric (selected by SW[5:3])
    //              1 = Dual Split Mode (Left 4 digits = C Program, Right 4 digits = Profiler)
    // SW[15:13]: Left 4-Digit Display Source (in Split Mode):
    //              000: Current C Operation Result (matches SW[11:9])
    //              001: Op 0 Matrix Inversion Result (0x1F0)
    //              010: Op 1 Vector Dot Product Result (0x1F4)
    //              011: Op 2 Array Sum Result (0x1E8)
    //              100: Op 3 Strided Transpose Result (0x1EC)
    //              101: Combined Grand Total Checksum (0x1FC)
    //              110: Live Program Counter PC[15:0]
    //              111: Program Done Flag (0x0001 when completed)
    // ------------------------------------------------------------------------
    wire [1:0] latency_sel     = sw[1:0];
    wire       cache_bypass    = sw[2];
    wire [2:0] prof_sw         = sw[5:3];
    wire       slow_clk_sel    = sw[6];
    wire       victim_cache_en = sw[7];
    wire       prefetch_en     = sw[8];
    wire [2:0] op_sel          = sw[11:9];
    wire       split_mode      = sw[12];
    wire [2:0] left_sel        = sw[15:13];

    // ------------------------------------------------------------------------
    // Clock Generation
    // Nexys A7 provides 100 MHz at pin E3.
    // cpu_clk_50m : 50 MHz generated via clean 2-divider
    // cpu_clk_1hz : 1 Hz generated via 50-million divider for visual stepping
    // ------------------------------------------------------------------------
    reg cpu_clk_50m = 1'b0;
    always @(posedge clk) begin
        cpu_clk_50m <= ~cpu_clk_50m;
    end

    reg [25:0] clk_cnt = 26'd0;
    reg        cpu_clk_1hz = 1'b0;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            clk_cnt     <= 26'd0;
            cpu_clk_1hz <= 1'b0;
        end else begin
            if (clk_cnt == 26'd49_999_999) begin
                clk_cnt     <= 26'd0;
                cpu_clk_1hz <= ~cpu_clk_1hz;
            end else begin
                clk_cnt <= clk_cnt + 1'b1;
            end
        end
    end

    wire cpu_clk = slow_clk_sel ? cpu_clk_1hz : cpu_clk_50m;

    // Reset synchronization: Core reset is active-low (~reset)
    reg rst_sync_0 = 1'b1;
    reg rst_sync_1 = 1'b1;
    always @(posedge cpu_clk or posedge reset) begin
        if (reset) begin
            rst_sync_0 <= 1'b1;
            rst_sync_1 <= 1'b1;
        end else begin
            rst_sync_0 <= 1'b0;
            rst_sync_1 <= rst_sync_0;
        end
    end
    wire sys_rst_n = ~rst_sync_1;
    wire sys_rst   = rst_sync_1;

    // ------------------------------------------------------------------------
    // CPU Pipeline Wires
    // ------------------------------------------------------------------------
    wire        exception;
    wire [31:0] pc_out;
    wire [31:0] inst_mem_read_data;

    wire        dmem_read_ready;
    wire [31:0] dmem_read_address;
    wire        dmem_write_ready;
    wire [31:0] dmem_write_address;
    wire [31:0] dmem_write_data;
    wire [ 3:0] dmem_write_byte;
    wire [31:0] dmem_read_data;
    wire        dmem_stall;

    // Profiler Strobes
    wire l1_access;
    wire l1_hit;
    wire l1_miss;
    wire vc_hit;
    wire mem_stall;
    wire frozen;
    wire [31:0] dmem_load_pc;
    wire        dmem_is_load;
    wire        prefetch_hit;

    // Mailbox termination & result capture
    reg done = 1'b0;
    reg [31:0] op0_result      = 32'd0; // Op 0: Matrix Inversion * B (0x1F0)
    reg [31:0] op1_result      = 32'd0; // Op 1: Vector Dot-Product   (0x1F4)
    reg [31:0] op2_result      = 32'd0; // Op 2: Array Accumulation   (0x1E8)
    reg [31:0] op3_result      = 32'd0; // Op 3: Strided Transpose    (0x1EC)
    reg [31:0] combined_result = 32'd0; // Combined Grand Total       (0x1FC)

    always @(posedge cpu_clk or posedge sys_rst) begin
        if (sys_rst) begin
            done            <= 1'b0;
            op0_result      <= 32'd0;
            op1_result      <= 32'd0;
            op2_result      <= 32'd0;
            op3_result      <= 32'd0;
            combined_result <= 32'd0;
        end else if (dmem_write_ready && !dmem_stall) begin
            if (dmem_write_address == 32'h0000_01F8 && dmem_write_data == 32'h0000_0001) begin
                done <= 1'b1;
            end
            if (dmem_write_address == 32'h0000_01F0) begin
                op0_result <= dmem_write_data;
            end
            if (dmem_write_address == 32'h0000_01F4) begin
                op1_result <= dmem_write_data;
            end
            if (dmem_write_address == 32'h0000_01E8) begin
                op2_result <= dmem_write_data;
            end
            if (dmem_write_address == 32'h0000_01EC) begin
                op3_result <= dmem_write_data;
            end
            if (dmem_write_address == 32'h0000_01FC) begin
                combined_result <= dmem_write_data;
            end
        end
    end

    wire [31:0] selected_op_result = (op_sel == 3'b000) ? op0_result :
                                     (op_sel == 3'b001) ? op1_result :
                                     (op_sel == 3'b010) ? op2_result :
                                     (op_sel == 3'b011) ? op3_result :
                                     (op_sel == 3'b100) ? combined_result :
                                     (op_sel == 3'b101) ? {31'd0, done} :
                                     32'h0000_0000;

    // Left display value generation (selected by SW[15:13] in split mode)
    wire [15:0] left_display_val = (left_sel == 3'b000) ? selected_op_result[15:0] :
                                   (left_sel == 3'b001) ? op0_result[15:0] :
                                   (left_sel == 3'b010) ? op1_result[15:0] :
                                   (left_sel == 3'b011) ? op2_result[15:0] :
                                   (left_sel == 3'b100) ? op3_result[15:0] :
                                   (left_sel == 3'b101) ? combined_result[15:0] :
                                   (left_sel == 3'b110) ? pc_out[15:0] :
                                   {15'd0, done};

    // ------------------------------------------------------------------------
    // Instantiate RV32IM 3-Stage Pipeline Core
    // ------------------------------------------------------------------------
    pipe #(
        .RESET   (32'h0000_0000),
        .MUL_FAST(1)
    ) pipe_u (
        .clk                (cpu_clk),
        .reset              (sys_rst_n),
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
        .dmem_write_byte    (dmem_write_byte),
        .dmem_load_pc       (dmem_load_pc),
        .dmem_is_load       (dmem_is_load)
    );

    // ------------------------------------------------------------------------
    // Instantiate 16 KB Instruction Memory (BRAM)
    // ------------------------------------------------------------------------
    instr_mem #(
        .MEM_BYTES(IMEMSIZE),
        .HEX_FILE (IMEM_HEX)
    ) IMEM (
        .clk  (cpu_clk),
        .pc   (pc_out),
        .instr(inst_mem_read_data)
    );

    // ------------------------------------------------------------------------
    // Instantiate Unified Memory Subsystem (L1 Cache + Configurable Latency BRAM)
    // ------------------------------------------------------------------------
    mem_subsystem #(
        .ADDR_WIDTH (32),
        .DATA_WIDTH (32),
        .MEM_BYTES  (DMEMSIZE),
        .INIT_FILE  (MEM128_HEX),
        .LATENCY    (10)
    ) mem_subsystem_inst (
        .clk                 (cpu_clk),
        .rst                 (sys_rst),
        .latency_sel         (latency_sel),
        .cache_bypass        (cache_bypass),
        .victim_cache_en     (victim_cache_en),
        .prefetch_en         (prefetch_en),
        .load_pc             (dmem_load_pc),
        .is_load             (dmem_is_load),
        .prefetch_hit        (prefetch_hit),
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
    // Instantiate Hardware Performance Profiler & 7-Segment Display Driver
    // Runs on fast 100 MHz board clock for flicker-free display multiplexing
    // ------------------------------------------------------------------------
    // Telemetry counter signals for live UART transmission
    wire [31:0] prof_total_cycles;
    wire [31:0] prof_stall_cycles;
    wire [31:0] prof_l1_accesses;
    wire [31:0] prof_l1_misses;
    wire [31:0] prof_victim_hits;
    wire [31:0] prof_prefetch_hits;

    perf_profiler #(
        .REFRESH_BITS(18) // ~190 Hz refresh at 50 MHz cpu_clk
    ) profiler_inst (
        .clk              (cpu_clk),
        .rst              (sys_rst),
        .done             (done),
        .mem_stall        (mem_stall),
        .l1_access        (l1_access),
        .l1_hit           (l1_hit),
        .l1_miss          (l1_miss),
        .victim_hit       (vc_hit),
        .prefetch_hit     (prefetch_hit),
        .sw               (prof_sw),
        .custom_val       (selected_op_result),
        .split_mode       (split_mode),
        .left_val         (left_display_val),
        .seg              (seg),
        .an               (an),
        .dp               (dp),
        .frozen           (frozen),
        .out_total_cycles (prof_total_cycles),
        .out_stall_cycles (prof_stall_cycles),
        .out_l1_accesses  (prof_l1_accesses),
        .out_l1_misses    (prof_l1_misses),
        .out_victim_hits  (prof_victim_hits),
        .out_prefetch_hits(prof_prefetch_hits)
    );

    // Live UART Telemetry Engine for Web Dashboard (115200 baud, pin D4)
    uart_reporter #(
        .CLK_FREQ_HZ(100_000_000),
        .REPORT_INTERVAL_CYCLES(5_000_000) // 20 Hz periodic telemetry
    ) u_uart_reporter (
        .clk          (clk),
        .rst          (sys_rst),
        .total_cycles (prof_total_cycles),
        .stall_cycles (prof_stall_cycles),
        .l1_accesses  (prof_l1_accesses),
        .l1_misses    (prof_l1_misses),
        .victim_hits  (prof_victim_hits),
        .prefetch_hits(prof_prefetch_hits),
        .sw           (sw),
        .uart_tx_pin  (uart_tx)
    );

    // ------------------------------------------------------------------------
    // Status LEDs
    // ------------------------------------------------------------------------
    // led[15]    : Program done / frozen flag
    // led[14]    : Memory stall indicator
    // led[13]    : Split-screen mode active indicator (sw[12])
    // led[12]    : Program Counter bit [5] / live core activity
    // led[11:9]  : Active Operation selected (sw[11:9])
    // led[8]     : Prefetcher Enable indicator (sw[8])
    // led[7]     : Victim Cache Enable indicator (sw[7])
    // led[6]     : Clock mode indicator (sw[6])
    // led[5:3]   : Active 7-segment counter selector (prof_sw)
    // led[2]     : Cache Bypass indicator (sw[2])
    // led[1:0]   : Latency setting (sw[1:0])
    // ------------------------------------------------------------------------
    assign led[15]    = frozen;
    assign led[14]    = mem_stall;
    assign led[13]    = split_mode;
    assign led[12]    = pc_out[5];
    assign led[11:9]  = op_sel;
    assign led[8]     = prefetch_en;
    assign led[7]     = victim_cache_en;
    assign led[6]     = slow_clk_sel;
    assign led[5:3]   = prof_sw;
    assign led[2]     = cache_bypass;
    assign led[1:0]   = latency_sel;

endmodule
