module instr_mem #(
	parameter MEM_BYTES = 16384,
	parameter HEX_FILE  = "imem.hex"
)(
	input  wire    	clk,
	input  wire [31:0] pc, 	// byte address
	output reg  [31:0] instr
);

	// Declare instruction memory array (word-addressable)
	(* ram_style = "block" *)
	reg [31:0] imem [0:(MEM_BYTES/4)-1];

	// FPGA ROM initialization
	// Initialize instruction memory from hex file (simulation / FPGA)
	initial begin
		if (HEX_FILE != "") begin
			$readmemh(HEX_FILE, imem);
		end
	end

	// Synchronous instruction fetch
	// Use word-aligned PC to index memory
	always @(posedge clk) begin
		instr <= imem[pc[$clog2(MEM_BYTES)-1:2]];	// word address
	end

endmodule



//====================================
// Data Memory (DMEM) - FPGA-safe
//====================================
module data_mem #(
	parameter MEM_BYTES = 16384,
	parameter HEX_FILE  = "dmem.hex"
)(
	input     	clk,

	// Read port
	input     	re,
	input  [31:0] raddr,   // byte address
	output reg [31:0] rdata,

	// Write port
	input     	we,
	input  [31:0] waddr,   // byte address
	input  [31:0] wdata,
	input  [3:0]  wstrb
);

	// Declare data memory array (word-addressable)
	// TODO-DMEM-1: Declare dmem
    (* ram_style = "block" *)
    reg [31:0] dmem [0:(MEM_BYTES/4)-1];
	// Decode byte address to word index
	wire [$clog2(MEM_BYTES)-3:0] rindex = raddr[$clog2(MEM_BYTES)-1:2];
	wire [$clog2(MEM_BYTES)-3:0] windex = waddr[$clog2(MEM_BYTES)-1:2];

	// Simulation / FPGA init
	// TODO-DMEM-2: Initialize data memory from hex file
    initial begin
        if (HEX_FILE != "") begin
            $readmemh(HEX_FILE, dmem);
        end
    end
	// -------------------------
	// WRITE + READ (SYNC)
	// -------------------------

	// Synchronous write and read logic
	// - Support byte-wise writes using wstrb
	// - Provide 1-cycle read latency
	// - Handle same-cycle read-after-write using byte-level forwarding

	always @(posedge clk) begin
    	// ---- WRITE ----
    	if (we) begin
        	if (wstrb[0]) dmem[windex][7:0]   <= wdata[7:0];
        	if (wstrb[1]) dmem[windex][15:8]  <= wdata[15:8];
        	if (wstrb[2]) dmem[windex][23:16] <= wdata[23:16]; // TODO-DMEM-3
        	if (wstrb[3]) dmem[windex][31:24] <= wdata[31:24]; // TODO-DMEM-3
    	end

    	// ---- READ (1-cycle latency, RAW-safe) ----
    	if (re) begin
        	if (we && (rindex == windex)) begin
            	// Byte-level forwarding
            	rdata[7:0]   <= wstrb[0] ? wdata[7:0]   : dmem[rindex][7:0];
            	rdata[15:8]  <= wstrb[1] ? wdata[15:8]  : dmem[rindex][15:8]; // TODO-DMEM-3
            	rdata[23:16] <= wstrb[2] ? wdata[23:16] : dmem[rindex][23:16]; // TODO-DMEM-3
            	rdata[31:24] <= wstrb[3] ? wdata[31:24] : dmem[rindex][31:24]; // TODO-DMEM-3
        	end
        	else begin
            	rdata <= dmem[rindex];
        	end
    	end
    	// else: rdata holds value (exact match to original)
	end

endmodule