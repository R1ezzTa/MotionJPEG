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
// The Xilinx fork defaults to inferred block RAM. The original vendor branch
// is retained only for source comparison; do not define JPEG_ANLOGIC_RAM.
`ifndef JPEG_ANLOGIC_RAM
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
`else
    // Instantiate the memory element directly: TD 6.0.3 otherwise duplicates
    // inferred read ports and falls back to distributed RAM after flattening.
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
    localparam MEM_ADDR_WIDTH = address_bits(DEPTH);
    PH1_LOGIC_ERAM #(
        .DATA_WIDTH_A(DATA_WIDTH),
        .DATA_WIDTH_B(DATA_WIDTH),
        .ADDR_WIDTH_A(MEM_ADDR_WIDTH),
        .ADDR_WIDTH_B(MEM_ADDR_WIDTH),
        .DATA_DEPTH_A(1 << MEM_ADDR_WIDTH),
        .DATA_DEPTH_B(1 << MEM_ADDR_WIDTH),
        .MODE        ("DP"),
        .REGMODE_A   ("NOREG"),
        .REGMODE_B   ("NOREG"),
        .CLKMODE     ("SYNC")
    ) memory (
        .clka          (clk),
        .clkb          (clk),
        .cea           (we),
        .ceb           (re),
        .ocea          (1'b1),
        .oceb          (1'b1),
        .wea           (we),
        .web           (1'b0),
        .rsta          (1'b0),
        .rstb          (1'b0),
        .bea           (1'b1),
        .beb           (1'b1),
        .dia           (wr_data),
        .dib           ({DATA_WIDTH{1'b0}}),
        .addra         (wr_addr[MEM_ADDR_WIDTH-1:0]),
        .addrb         (rd_addr[MEM_ADDR_WIDTH-1:0]),
        .doa           (),
        .dob           (rd_data),
        .ecc_sbiterr   (),
        .ecc_dbiterr   (),
        .ecc_sbiterrinj(1'b0),
        .ecc_dbiterrinj(1'b0)
    );
`endif
endmodule
