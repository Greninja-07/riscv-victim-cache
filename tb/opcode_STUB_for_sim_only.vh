// TEST-ONLY stand-in for the project's opcode.vh (standard RV32I encodings)
`define OPCODE  6:0
`define FUNC3   14:12
`define SUBTYPE 30
`define RD      11:7
`define RS1     19:15
`define RS2     24:20
localparam [31:0] NOP    = 32'h00000013;
localparam [6:0]  LUI    = 7'b0110111;
localparam [6:0]  JAL    = 7'b1101111;
localparam [6:0]  JALR   = 7'b1100111;
localparam [6:0]  BRANCH = 7'b1100011;
localparam [6:0]  LOAD   = 7'b0000011;
localparam [6:0]  STORE  = 7'b0100011;
localparam [6:0]  ARITHI = 7'b0010011;
localparam [6:0]  ARITHR = 7'b0110011;
localparam [2:0]  BEQ=3'd0, BNE=3'd1, BLT=3'd4, BGE=3'd5, BLTU=3'd6, BGEU=3'd7;
localparam [2:0]  LB=3'd0, LH=3'd1, LW=3'd2, LBU=3'd4, LHU=3'd5;
localparam [2:0]  SB=3'd0, SH=3'd1, SW=3'd2;
localparam [2:0]  ADD=3'd0, SLL=3'd1, SLT=3'd2, SLTU=3'd3, XOR=3'd4, SR=3'd5, OR=3'd6, AND=3'd7;
