`timescale 1ns / 1ps
module line_group_ram #(
    parameter DATA_WIDTH = 8,
    DEPTH = 7680,
    ADDR_WIDTH = 14
) (
    input clk,
    input we,
    input [ADDR_WIDTH-1:0] wr_addr,
    input [DATA_WIDTH-1:0] wr_data,
    input re,
    input [ADDR_WIDTH-1:0] rd_addr,
    output [DATA_WIDTH-1:0] rd_data
);
    // Infer the block RAM used by the current Xilinx camera pipeline.
    function integer address_bits;
        input integer depth;
        integer value;
        begin
            value = depth - 1;
            address_bits = 0;
            while (value > 0) begin
                address_bits = address_bits + 1;
                value = value >> 1;
            end
        end
    endfunction
    // Match the original physical ERAM depth and address truncation. The
    // frontend also reads inactive chroma lanes while producing luma blocks;
    // those speculative addresses need not be below the logical DEPTH.
    localparam MEM_ADDR_WIDTH = address_bits(DEPTH);
    reg [DATA_WIDTH-1:0] rd_reg;
    assign rd_data = rd_reg;
    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] mem[0:(1 << MEM_ADDR_WIDTH)-1];
    always @(posedge clk) if (we) mem[wr_addr[MEM_ADDR_WIDTH-1:0]] <= wr_data;
    always @(posedge clk) if (re) rd_reg <= mem[rd_addr[MEM_ADDR_WIDTH-1:0]];
`ifndef SYNTHESIS
    // A behavioral read-first value must not conceal an undefined collision.
    always @(posedge clk) begin
        if (we && wr_addr >= DEPTH) $fatal(1, "RAM write address out of range");
        if (we && re && wr_addr[MEM_ADDR_WIDTH-1:0] == rd_addr[MEM_ADDR_WIDTH-1:0])
            $fatal(1, "Unsupported RAM read/write collision");
    end
`endif
endmodule
