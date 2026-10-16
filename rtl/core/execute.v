`timescale 1ns/1ps

module execute
#(
    parameter [31:0] RESET = 32'h0000_0000
)
(
    input clk,
    input reset,

    // FROM ID/EX
    input  [31:0] reg_rdata1,
    input  [31:0] reg_rdata2,
    input  [31:0] execute_imm,
    input  [31:0] pc,
    input  [31:0] fetch_pc,
    input         immediate_sel,
    input         mem_write,
    input         jal,
    input         jalr,
    input         lui,
    input         alu,
    input         muldiv,        // RV32M instruction in EX
    input         branch,
    input         arithsubtype,
    input         mem_to_reg,
    input         stall_read,

    input  [4:0]  dest_reg_sel,
    input  [2:0]  alu_op,
    input  [1:0]  dmem_raddr,

    // FROM WB
    input         wb_branch_i,
    input         wb_branch_nxt_i,

    // EX -> PIPE
    output [31:0] alu_operand1,
    output [31:0] alu_operand2,
    output [31:0] write_address,
    output        branch_stall,

    output reg [31:0] next_pc,
    output reg    branch_taken,

    // EX -> WB
    output        md_stall,      // RV32M: EX is busy -> freeze IF/ID/EX, bubble into WB
    output [31:0] wb_result,
    output        wb_mem_write,
    output        wb_alu_to_reg,
    output [4:0]  wb_dest_reg_sel,
    output        wb_branch,
    output        wb_branch_nxt,
    output        wb_mem_to_reg,
    output [1:0]  wb_read_address,
    output [2:0]  mem_alu_operation
);

`include "opcode.vh"

reg  [31:0] ex_result;
wire [31:0] md_result;
wire        md_done;
wire [32:0] ex_result_subs;
wire [32:0] ex_result_subu;
////////////////////////////////////////////////////////////// Operand selection///////////////////////////////////////////////////////

// TODO-EX-1:
// Select ALU operands
// - The first operand must come from the first value read from the register file
// - The second operand must come from the immediate when immediate selection is enabled
// - Otherwise, the second operand must come from the second value read from the register file

assign alu_operand1 = reg_rdata1;
assign alu_operand2 = immediate_sel ? execute_imm : reg_rdata2;
//assign alu_operand2 = immediate_sel
//                    	? TODO-EX-1;

////////////////////////////////////////////////////////////// Subtractions////////////////////////////////////////////////////////////


// TODO-EX-2:
// Generate subtraction results required for branch comparison
// - One result (ex_result_subs) must treat both operands as signed values
// - Another result (ex_result_subu) must treat both operands as unsigned values
// - The results must be wide enough to capture the sign/borrow bit
// - These results will be used later to evaluate branch conditions


// Subtractions with 1-bit extension to catch overflow for comparisons
assign ex_result_subs = {alu_operand1[31], alu_operand1} - {alu_operand2[31], alu_operand2};
assign ex_result_subu = {1'b0, alu_operand1} - {1'b0, alu_operand2};
//assign ex_result_subu = TODO-EX-2
assign write_address = alu_operand1 + execute_imm;
assign branch_stall  = wb_branch_nxt_i || wb_branch_i;

////////////////////////////////////////////////////////////// RV32M MUL/DIV unit////////////////////////////////////////////////////////////
// - an M instruction that is on the wrong path of a taken branch (branch_stall = 1) is squashed: it never starts
// - md_stall = 1 while the unit is busy: pipeline front-end is frozen and a bubble (no reg write)
//   is pushed into the EX/MEM register; on the cycle done = 1 the result is passed on like any ALU result
wire md_valid   = muldiv && !branch_stall;
assign md_stall = md_valid && !md_done;
wire md_advance = !stall_read && !md_stall;     // EX/MEM register is loaded this cycle

muldiv_unit #(.MUL_FAST(0)) u_muldiv (         // MUL_FAST = 1 -> single-cycle DSP multiply
    .clk     (clk),
    .reset_n (reset),
    .valid   (md_valid),
    .advance (md_advance),
    .funct3  (alu_op),
    .a       (alu_operand1),
    .b       (alu_operand2),
    .done    (md_done),
    .result  (md_result)
);

////////////////////////////////////////////////////////////// Next PC logic////////////////////////////////////////////////////////////


// TODO-EX-3:
// Compute the next program counter and branch decision
// Guidelines:
// - Default next PC advances to the next sequential instruction
// - For jump instructions:
// 	* JAL computes the target using the current PC and an immediate
// 	* JALR computes the target using a register value (first read) and an immediate
// - For branch instructions:
// 	* Evaluate the branch condition using comparison/subtraction results
// 	* If the condition is satisfied, jump to the branch target
// 	* Otherwise, continue sequential execution
// - Branch resolution must be suppressed when a branch stall is active
//todo 3
always @(*) begin
    next_pc      = fetch_pc + 4;
    branch_taken = !branch_stall;

    case (1'b1)
        jal  : next_pc = pc + execute_imm;
        jalr : next_pc = alu_operand1 + execute_imm;

        branch: begin
            case (alu_op)
                BEQ:  begin
                    next_pc = (ex_result_subs == 0) ? pc + execute_imm : fetch_pc + 4;
                    if (ex_result_subs != 0) branch_taken = 1'b0;
                end
                BNE:  begin //todo
                    next_pc = (ex_result_subs != 0) ? pc + execute_imm : fetch_pc + 4;
                    if (ex_result_subs == 0) branch_taken = 1'b0;
                end
                BLT:  begin //todo
                    next_pc = ex_result_subs[32] ? pc + execute_imm : fetch_pc + 4;
                    if (!ex_result_subs[32]) branch_taken = 1'b0;
                end
                BGE:  begin //todo
                    next_pc = !ex_result_subs[32] ? pc + execute_imm : fetch_pc + 4;
                    if (ex_result_subs[32]) branch_taken = 1'b0;
                end
                BLTU: begin //todo
                    next_pc = ex_result_subu[32] ? pc + execute_imm : fetch_pc + 4;
                    if (!ex_result_subu[32]) branch_taken = 1'b0;
                end
                BGEU: begin //todo
                    next_pc = !ex_result_subu[32] ? pc + execute_imm : fetch_pc + 4;
                    if (ex_result_subu[32]) branch_taken = 1'b0;
                end
                default: next_pc = fetch_pc + 4; // sequential execution
            endcase
        end

        default: begin       
            next_pc      = fetch_pc + 4; //bug fixed
            branch_taken = 1'b0;
        end
    endcase
end


////////////////////////////////////////////////////////////// ALU result logic////////////////////////////////////////////////////////////

// TODO-EX-4:
// Generate the execute-stage result (ex_result)
// Guidelines:
// - For store instructions, forward the value that will be written to memory
// - For jump instructions (JAL/JALR), produce the return address (PC + 4)
// - LUI must place the immediate value directly into the destination register
// - For ALU instructions, compute the result based on the decoded ALU operation
// - The arithmetic subtype signal selects between related operations

always @(*) begin
    case (1'b1)
        mem_write: ex_result = alu_operand2;
        jal,
        jalr:      ex_result = pc + 4;
        lui:       ex_result = execute_imm;

        alu: begin
          if (muldiv) ex_result = md_result;     // RV32M
          else
            case (alu_op)
                ADD : ex_result = arithsubtype ? alu_operand1 - alu_operand2 : alu_operand1 + alu_operand2;
                SLL : ex_result = alu_operand1 << alu_operand2[4:0];//todo
                SLT : ex_result = {31'b0, ex_result_subs[32]}; // set less than (signed)
                SLTU: ex_result = {31'b0, ex_result_subu[32]}; // set less than (unsigned)
                XOR : ex_result = alu_operand1 ^ alu_operand2;//todo
                SR  : ex_result = arithsubtype ? $signed(alu_operand1) >>> alu_operand2[4:0] : alu_operand1 >> alu_operand2[4:0];
                OR  : ex_result = alu_operand1 | alu_operand2;//todo
                AND : ex_result = alu_operand1 & alu_operand2;//todo
                default: ex_result = 'hx;
            endcase
        end

        default: ex_result = 'hx;
    endcase
end

ex_mem_wb_reg u_ex_mem_wb (
    .clk                  (clk),
    .reset_n              (reset),
    .stall_n              (!stall_read),  // active-low: hold when stalled
    .ex_result            (ex_result),
    .mem_write            (mem_write && !branch_stall),
    .alu_to_reg           ((alu | lui | jal | jalr | mem_to_reg) && !md_stall && !branch_stall),  // bubble while MUL/DIV busy; squash wrong-path write
    .dest_reg_sel         (dest_reg_sel),
    .branch_taken         (branch_taken),
    .mem_to_reg           (mem_to_reg),
    .read_address         (dmem_raddr),
    .alu_operation        (alu_op),
    .ex_mem_result        (wb_result),
    .ex_mem_mem_write     (wb_mem_write),
    .ex_mem_alu_to_reg    (wb_alu_to_reg),
    .ex_mem_dest_reg_sel  (wb_dest_reg_sel),
    .ex_mem_branch        (wb_branch),
    .ex_mem_branch_nxt    (wb_branch_nxt),
    .ex_mem_mem_to_reg    (wb_mem_to_reg),
    .ex_mem_read_address  (wb_read_address),
    .ex_mem_alu_operation (mem_alu_operation)
);

endmodule


module ex_mem_wb_reg (
    input         clk,
    input         reset_n,
    input         stall_n,
    input  [31:0] ex_result,
    input         mem_write,
    input         alu_to_reg,
    input  [4:0]  dest_reg_sel,
    input         branch_taken,
    input         mem_to_reg,
    input  [1:0]  read_address,
    input  [2:0]  alu_operation,

    output reg [31:0] ex_mem_result,
    output reg        ex_mem_mem_write,
    output reg        ex_mem_alu_to_reg,
    output reg [4:0]  ex_mem_dest_reg_sel,
    output reg        ex_mem_branch,
    output reg        ex_mem_branch_nxt,
    output reg        ex_mem_mem_to_reg,
    output reg [1:0]  ex_mem_read_address,
    output reg [2:0]  ex_mem_alu_operation
);

// TODO-EX-5:
// EX/MEM → WB pipeline register
// Guidelines:
// - Store all execute-stage data and control signals on the rising clock edge
// - On reset, clear all stored values to a safe default
// - When a stall is asserted, prevent unintended updates
// - All outputs must hold their previous values unless explicitly updated

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        ex_mem_result        <= 32'h0;
        ex_mem_mem_write     <= 1'b0;
        ex_mem_alu_to_reg    <= 1'b0;
        ex_mem_dest_reg_sel  <= 5'h0;
        ex_mem_branch        <= 1'b0;
        ex_mem_branch_nxt    <= 1'b0;
        ex_mem_mem_to_reg    <= 1'b0;
        ex_mem_read_address  <= 2'h0;
        ex_mem_alu_operation <= 3'h0;
    end
    // stall_n is active-low: 0 = hold (stalled), 1 = update (advance)
    else if (stall_n) begin
        ex_mem_result        <= ex_result;//todo
        ex_mem_mem_write     <= mem_write;//todo
        ex_mem_alu_to_reg    <= alu_to_reg;//todo
        ex_mem_dest_reg_sel  <= dest_reg_sel;//todo
        ex_mem_branch        <= branch_taken;//todo
        ex_mem_branch_nxt    <= ex_mem_branch;   //todo
        ex_mem_mem_to_reg    <= mem_to_reg;//todo
        ex_mem_read_address  <= read_address;//todo
        ex_mem_alu_operation <= alu_operation;//todo
    end
end
endmodule