`timescale 1ns / 1ps
// Isolated prefetcher demonstration: 20 full clock periods, actual N=10 memory.
module tb_prefetcher_timing;
    reg clk;
    initial clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg is_load = 0;
    reg [31:0] load_addr = 0;
    reg l1_mem_req = 0;
    reg [31:0] l1_mem_addr = 0;
    wire main_mem_req, main_mem_we, main_mem_ack, l1_mem_ack, prefetch_hit;
    wire [31:0] main_mem_addr;
    wire [127:0] main_mem_wdata, main_mem_rdata, l1_mem_rdata;
    wire [1:0] rpt_conf = dut.rpt_conf[0];
    prefetcher dut (
        .clk(clk), .rst(rst), .prefetch_en(1'b1), .cache_bypass(1'b0),
        .is_load(is_load), .load_pc(32'h1000), .load_addr(load_addr), .load_stall(1'b0),
        .store_valid(1'b0), .store_addr(32'b0), .l1_idle(!l1_mem_req), .l1_tag_hit(1'b0),
        .l1_mem_req(l1_mem_req), .l1_mem_we(1'b0), .l1_mem_addr(l1_mem_addr),
        .l1_mem_wdata(128'b0), .l1_mem_rdata(l1_mem_rdata), .l1_mem_ack(l1_mem_ack),
        .main_mem_req(main_mem_req), .main_mem_we(main_mem_we), .main_mem_addr(main_mem_addr),
        .main_mem_wdata(main_mem_wdata), .main_mem_rdata(main_mem_rdata),
        .main_mem_ack(main_mem_ack), .prefetch_hit(prefetch_hit)
    );
    main_memory mem (
        .clk(clk), .rst(rst), .latency_sel(2'b01), .mem_req(main_mem_req),
        .mem_we(main_mem_we), .mem_addr(main_mem_addr), .mem_wdata(main_mem_wdata),
        .mem_rdata(main_mem_rdata), .mem_ack(main_mem_ack)
    );
    integer cycle = 0;
    integer trace;
    // Half-cycle samples follow NBA/combinational settling; plotting uses these values.
    always @(clk) begin
        #0.001;
        $fdisplay(trace, "%0.3f,%0d,%0d,%0d,%08h,%0d,%0d,%0d,%08h,%0d,%0d,%0d,%07h,%0d,%08h,%0d,%0d",
            $realtime, clk, rst, is_load, load_addr, rpt_conf, dut.pending_valid,
            main_mem_req, main_mem_addr, dut.inflight, main_mem_ack, dut.pf_valid,
            dut.pf_tag, l1_mem_req, l1_mem_addr, l1_mem_ack, prefetch_hit);
    end
    always @(posedge clk) begin
        cycle = cycle + 1;
        // L1 drops its request on the same edge that samples the acknowledgement.
        if (l1_mem_req && l1_mem_ack) begin
            l1_mem_req <= 0;
            l1_mem_addr <= 0;
        end
        #1;
        case (cycle)
            1,2,3: if (rpt_conf !== 0) $fatal(1, "INIT timing mismatch");
            4: if (rpt_conf !== 1) $fatal(1, "TRANSIENT timing mismatch");
            5: if (rpt_conf !== 2 || !dut.pending_valid || !main_mem_req || dut.inflight)
                $fatal(1, "Prediction/pending timing mismatch");
            6: if (!dut.inflight || dut.pending_valid || main_mem_addr !== 32'h140)
                $fatal(1, "Prefetch launch mismatch");
            15: if (!main_mem_ack || dut.pf_valid || !dut.inflight)
                $fatal(1, "Memory acknowledgement timing mismatch");
            16: if (!dut.pf_valid || dut.pf_tag !== 28'h14 || dut.inflight || main_mem_req)
                $fatal(1, "Buffer fill mismatch");
            17: if (dut.pf_valid || !prefetch_hit || main_mem_req)
                $fatal(1, "Buffer consumption mismatch");
            18: if (prefetch_hit || dut.pf_tag !== 28'h14)
                $fatal(1, "Hit clear / retained tag mismatch");
        endcase
    end
    initial begin
        trace = $fopen("docs/prefetcher_timing_20cycles.csv", "w");
        $fdisplay(trace, "time_ns,clk,rst,is_load,load_addr,rpt_conf,pending_valid,main_mem_req,main_mem_addr,inflight,main_mem_ack,pf_valid,pf_tag,l1_mem_req,l1_mem_addr,l1_mem_ack,prefetch_hit");
        $dumpfile("docs/prefetcher_timing_20cycles.vcd");
        $dumpvars(0, tb_prefetcher_timing);
        @(negedge clk); rst = 0; is_load = 1; load_addr = 32'h100;
        @(negedge clk); load_addr = 32'h110;
        @(negedge clk); load_addr = 32'h120;
        @(negedge clk); load_addr = 32'h130;
        @(negedge clk); is_load = 0; load_addr = 0;
        repeat (11) @(negedge clk);
        l1_mem_req = 1; l1_mem_addr = 32'h140;
        #1;
        if (!l1_mem_ack || !prefetch_hit || main_mem_req ||
            l1_mem_rdata !== mem.storage[20]) $fatal(1, "Combinational buffer hit/data mismatch");
        @(negedge clk); l1_mem_req = 0; l1_mem_addr = 0;
        repeat (3) @(negedge clk);
        #0.01;
        $fclose(trace);
        $display("PASS: 20 cycles; training, N=10 memory, buffer fill, hit data and consumption checked.");
        $finish;
    end
endmodule
