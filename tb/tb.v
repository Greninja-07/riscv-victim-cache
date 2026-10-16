`timescale 1ns/1ps
module tb;
  parameter FAST = 0;
  reg clk=0, rst_n=0;
  always #5 clk=~clk;
  wire [31:0] imem_rd, dmem_rd, pc_out;
  wire dr, dw; wire [31:0] dra, dwa, dwd; wire [3:0] dwb; wire exc;
  pipe #(.MUL_FAST(FAST)) cpu(.clk(clk),.reset(rst_n),.stall(1'b0),.exception(exc),.pc_out(pc_out),
    .inst_mem_is_valid(1'b1),.inst_mem_read_data(imem_rd),.dmem_read_data_temp(dmem_rd),
    .dmem_write_valid(1'b1),.dmem_read_valid(1'b1),
    .dmem_read_ready(dr),.dmem_read_address(dra),.dmem_write_ready(dw),
    .dmem_write_address(dwa),.dmem_write_data(dwd),.dmem_write_byte(dwb));
  instr_mem IMEM(.clk(clk),.pc(pc_out),.instr(imem_rd));
  data_mem DMEM(.clk(clk),.re(dr),.raddr(dra),.rdata(dmem_rd),.we(dw),.waddr(dwa),.wdata(dwd),.wstrb(dwb));
  integer cyc=0, maxc;
  initial begin
    if(!$value$plusargs("MAXC=%d",maxc)) maxc=20000;
    #22 rst_n=1;
  end
  always @(posedge clk) begin
    cyc<=cyc+1;
    if (dw && dwb!=0) $display("W %0d %08x %08x", dwa, dwd, dwb);
    if (cyc>=maxc) begin $display("END %0d",cyc); $finish; end
  end
endmodule
