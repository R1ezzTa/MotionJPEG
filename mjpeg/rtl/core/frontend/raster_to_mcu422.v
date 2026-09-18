// YUYV raster -> two samples/cycle, MCU order Y0,Y1,Cb,Cr.
// Six even/odd memories per bank permit synchronous two-sample reads.
module raster_to_mcu422 #(
    parameter MAX_WIDTH = 1920
) (
    input clk,
    input rst_n,
    input [15:0] cfg_width, cfg_height,
    input cfg_gray,
    input [15:0] s_data,
    input s_valid,
    output s_ready,
    input s_sof, s_eol, s_eof,
    output reg [15:0] m_data,
    output reg m_valid,
    input m_ready,
    output reg [1:0] m_component,
    output reg [4:0] m_pair,
    output reg m_frame_start, m_frame_end,
    output reg protocol_error,
    output input_frame_end
);
    localparam YDEPTH = MAX_WIDTH * 4, CDEPTH = MAX_WIDTH * 2;
    reg [15:0] width, height, last_x, last_y, x, y;
    reg gray, active, wr_bank, rd_bank;
    reg [1:0] full;
    reg [15:0] bank_row[0:1];
    reg reading;
    reg [15:0] mcu;
    reg [1:0] block_no;
    reg [4:0] pair_no;
    wire dimensions_ok = (cfg_width != 0) && (cfg_width <= MAX_WIDTH) && (cfg_height != 0) &&
        (cfg_height[2:0] == 0) && (cfg_gray ? cfg_width[2:0] == 0 : cfg_width[3:0] == 0);
    assign s_ready = !full[wr_bank] && (active || (s_sof && dimensions_ok));
    wire put = s_valid && s_ready;
    wire [15:0] wx = x, wy = y;
    wire wg = active ? gray : cfg_gray;
    // Valid dimensions are at least 8x8. The first pixel cannot end a line.
    // Cache limits at SOF rather than subtracting them on every pixel clock.
    wire line_end = active && (x == last_x);
    wire frame_end = line_end && (y == last_y);
    assign input_frame_end = put && frame_end;
    wire ce = !m_valid || m_ready;
    wire req = ce && (reading || full[rd_bank]);
    wire [1:0] comp = gray ? 2'd0 : (block_no < 2 ? 2'd0 : block_no - 1'b1);
    wire [15:0] rx = gray ?
        (mcu * 8 + {pair_no[1:0], 1'b0}) : (comp == 0 ? mcu * 16 + block_no * 8 +
                                            {pair_no[1:0], 1'b0} : mcu * 8 + {pair_no[1:0], 1'b0});
    wire [13:0] ywa = wy[2:0] * (MAX_WIDTH / 2) + (wx >> 1);
    wire [13:0] cwa = wy[2:0] * (MAX_WIDTH / 4) + (wx >> 2);
    wire [13:0] yra = pair_no[4:2] * (MAX_WIDTH / 2) + (rx >> 1);
    wire [13:0] cra = pair_no[4:2] * (MAX_WIDTH / 4) + (rx >> 1);
    wire last_block = gray || (block_no == 3);
    wire last_mcu = gray ? mcu == (width / 8 - 1) : mcu == (width / 16 - 1);
    wire tail = (pair_no == 31) && last_block && last_mcu;
    reg pending, p_bank, p_tail, p_fs, p_fe;
    reg [1:0] p_comp;
    reg [4:0] p_pair;
    wire [7:0] rdata[0:11];
    genvar b, l;
    generate
        for (b = 0; b < 2; b = b + 1) begin : banks
            for (l = 0; l < 6; l = l + 1) begin : lanes
                wire write_lane = (l < 2) ? (wx[0] == l) :
                    (l < 4 ? (!wx[0] && wx[1] == (l - 2)) : (wx[0] && wx[1] == (l - 4)));
                line_group_ram #(
                    .DATA_WIDTH(8),
                    .DEPTH     (l < 2 ? YDEPTH : CDEPTH),
                    .ADDR_WIDTH(14)
                ) ram (
                    .clk    (clk),
                    .we     (put && (wr_bank == b) && write_lane && (l < 2 || !wg)),
                    .wr_addr(l < 2 ? ywa : cwa),
                    .wr_data(l < 2 ? s_data[7:0] : s_data[15:8]),
                    .re     (req && (rd_bank == b)),
                    .rd_addr(l < 2 ? yra : cra),
                    .rd_data(rdata[b*6+l])
                );
            end
        end
    endgenerate
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            width <= 0;
            height <= 0;
            last_x <= 0;
            last_y <= 0;
            gray <= 1;
            x <= 0;
            y <= 0;
            active <= 0;
            wr_bank <= 0;
            rd_bank <= 0;
            full <= 0;
            reading <= 0;
            mcu <= 0;
            block_no <= 0;
            pair_no <= 0;
            pending <= 0;
            p_bank <= 0;
            p_tail <= 0;
            p_fs <= 0;
            p_fe <= 0;
            p_comp <= 0;
            p_pair <= 0;
            m_data <= 0;
            m_valid <= 0;
            m_component <= 0;
            m_pair <= 0;
            m_frame_start <= 0;
            m_frame_end <= 0;
            protocol_error <= 0;
            for (i = 0; i < 2; i = i + 1) bank_row[i] <= 0;
        end else begin
            if (put) begin
                if (!active) begin
                    width <= cfg_width;
                    height <= cfg_height;
                    last_x <= cfg_width - 1'b1;
                    last_y <= cfg_height - 1'b1;
                    gray <= cfg_gray;
                    protocol_error <= 0;
                end
                if (s_sof != (!active) || s_eol != line_end || s_eof != frame_end)
                    protocol_error <= 1;
                if (line_end) begin
                    x <= 0;
                    y <= frame_end ? 16'd0 : wy + 1'b1;
                    if (wy[2:0] == 7) begin
                        full[wr_bank] <= 1;
                        bank_row[wr_bank] <= wy >> 3;
                        wr_bank <= !wr_bank;
                    end
                end else x <= wx + 1'b1;
                active <= !frame_end;
            end
            if (ce) begin
                m_valid <= pending;
                if (pending) begin
                    case (p_comp)
                        0: m_data <= {rdata[p_bank*6+1], rdata[p_bank*6]};
                        1: m_data <= {rdata[p_bank*6+3], rdata[p_bank*6+2]};
                        default: m_data <= {rdata[p_bank*6+5], rdata[p_bank*6+4]};
                    endcase
                    m_component <= p_comp;
                    m_pair <= p_pair;
                    m_frame_start <= p_fs;
                    m_frame_end <= p_fe;
                    if (p_tail) full[p_bank] <= 0;
                end
                pending <= req;
                if (req) begin
                    p_comp <= comp;
                    p_pair <= pair_no;
                    p_bank <= rd_bank;
                    p_tail <= tail;
                    p_fs <= (bank_row[rd_bank] == 0) && (mcu == 0) && (block_no == 0) &&
                        (pair_no == 0);
                    p_fe <= tail && (bank_row[rd_bank] == (height / 8 - 1));
                    if (pair_no == 31) begin
                        pair_no <= 0;
                        if (last_block) begin
                            block_no <= 0;
                            if (last_mcu) mcu <= 0;
                            else mcu <= mcu + 1'b1;
                        end else block_no <= block_no + 1'b1;
                    end else pair_no <= pair_no + 1'b1;
                    if (tail) begin
                        reading <= 0;
                        rd_bank <= !rd_bank;
                    end else reading <= 1;
                end
            end
        end
    end
endmodule
