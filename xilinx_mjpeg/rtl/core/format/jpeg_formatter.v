module jpeg_formatter (
    input clk,
    input rst_n,
    input start,
    input [15:0] frame_width, frame_height,
    input frame_gray,
    output reg [6:0] q_read_addr,
    input [7:0] q_read_data,
    input [127:0] s_data,
    input [4:0] s_bytes,
    input s_frame_end, s_valid,
    output s_ready,
    output [127:0] m_data,
    output [4:0] m_bytes,
    output m_last, m_valid,
    input m_ready
);
    `include "rtl/generated/zigzag.vh"
    `include "rtl/generated/header.vh"
    localparam IDLE = 0, HEADER = 1, SCAN = 2, EOI = 3;
    reg [1:0] state;
    reg [9:0] index;
    wire [9:0] header_length = frame_gray ? 597 : 607;
    reg [5:0] q_cursor;
    reg [7:0] header_data;
    reg header_valid, header_last, header_done;
    wire header_ce = !header_valid || m_ready;
    reg [511:0] lookup_bytes;
    reg [5:0] lookup_bank;
    reg lookup_valid, lookup_last;
    wire lookup_ce = !lookup_valid || header_ce;
    assign m_valid = (state == HEADER && header_valid) || (state == EOI) ||
        (state == SCAN && s_valid && s_bytes != 0);
    assign m_data = state == HEADER ?
        {120'd0, header_data} : (state == EOI ? {112'd0, 16'hd9ff} : s_data);
    assign m_bytes = state == HEADER ? 5'd1 : (state == EOI ? 5'd2 : s_bytes);
    assign m_last = state == EOI;
    assign s_ready = state == SCAN && (s_bytes == 0 || m_ready);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            index <= 0;
            q_cursor <= 0;
            q_read_addr <= 0;
            header_data <= 0;
            header_valid <= 0;
            header_last <= 0;
            header_done <= 0;
            lookup_bytes <= 0;
            lookup_bank <= 0;
            lookup_valid <= 0;
            lookup_last <= 0;
        end else begin
            if (start) begin
                state <= HEADER;
                index <= 0;
                q_cursor <= 0;
                q_read_addr <= 0;
                header_valid <= 0;
                header_last <= 0;
                header_done <= 0;
                lookup_valid <= 0;
                lookup_last <= 0;
            end else if (state == HEADER) begin
                // Each 32-byte segment is looked up first, then the registered bank
                // selects one candidate. Both elastic stages hold while stalled.
                if (header_ce) begin
                    header_valid <= lookup_valid;
                    if (lookup_valid) begin
                        header_data <= lookup_bytes[lookup_bank*8+:8];
                        header_last <= lookup_last;
                    end
                end
                if (lookup_ce) begin
                    lookup_valid <= !header_done;
                    if (!header_done) begin
                        lookup_bytes <= header_lookup(
                            index[4:0], frame_width, frame_height, q_read_data
                        );
                        lookup_bank <= {!frame_gray, index[9:5]};
                        lookup_last <= index == header_length - 1;
                        if (index == header_length - 1) header_done <= 1;
                        else index <= index + 1'b1;
                        // Tables are locked for the frame. Prefetch the next DQT item so
                        // address arithmetic and the asynchronous table read occupy separate clocks.
                        if ((index >= 25 && index < 88) || (index >= 90 && index < 153)) begin
                            q_cursor <= q_cursor + 1'b1;
                            q_read_addr <= {index >= 90, zigzag(q_cursor + 1'b1)};
                        end else if (index == 88) begin
                            q_cursor <= 0;
                            q_read_addr <= 7'd64;
                        end
                    end
                end
                if (header_valid && m_ready && header_last) state <= SCAN;
            end else if (state == SCAN && s_valid && s_ready && s_frame_end) state <= EOI;
            else if (state == EOI && m_ready) state <= IDLE;
        end
    end
endmodule
