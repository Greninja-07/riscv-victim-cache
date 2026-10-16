`timescale 1ns/1ps
module tb_md;
  parameter FAST = 0;
  reg clk=0, rst_n=0, valid=0, advance=0;
  reg [2:0] f3; reg [31:0] a,b;
  wire done; wire [31:0] res;
  muldiv_unit #(.MUL_FAST(FAST)) u(.clk(clk),.reset_n(rst_n),.valid(valid),.advance(advance),.funct3(f3),.a(a),.b(b),.done(done),.result(res));
  always #5 clk=~clk;
  integer fd, n, cyc, r;
  reg [31:0] ta, tb_; reg [2:0] tf;
  initial begin
    fd=$fopen("md_vec.txt","r");
    #12 rst_n=1;
    while (!$feof(fd)) begin
      r=$fscanf(fd,"%h %h %h\n",tf,ta,tb_);
      if (r==3) begin
        @(negedge clk); f3=tf; a=ta; b=tb_; valid=1; advance=0; cyc=1;
        // wait for done (stall until done)
        @(negedge clk);
        while(!done) begin cyc=cyc+1; @(negedge clk); end
        $display("R %0d %08x %08x %08x %0d", tf, ta, tb_, res, cyc);
        advance=1; @(negedge clk); advance=0; valid=0;
      end
    end
    $finish;
  end
endmodule
