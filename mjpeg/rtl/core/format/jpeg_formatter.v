module jpeg_formatter #(parameter RESTART_MCUS=0) (
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
    localparam IDLE = 0, HEADER = 1, SCAN = 2, EOI = 3, RESTART = 4;
    reg [2:0] state;
    reg [2:0] restart_index;
    reg [31:0] remaining_mcus;
    reg [9:0] index;
    wire [9:0] header_length = (frame_gray ? 597 : 607)+(RESTART_MCUS!=0?6:0);
    wire [9:0] dri_offset=frame_gray?587:593;
    wire dri_byte=RESTART_MCUS!=0 && index>=dri_offset && index<dri_offset+6;
    wire [9:0] rom_index=RESTART_MCUS!=0 && index>=dri_offset+6?index-6:index;
    reg lookup_dri;
    reg [7:0] lookup_dri_data;
    function [7:0] dri_data;
        input [9:0] offset;
        begin case(offset)
            0:dri_data=8'hff;1:dri_data=8'hdd;2:dri_data=0;3:dri_data=4;
            4:dri_data=(RESTART_MCUS>>8)&255;default:dri_data=RESTART_MCUS&255;
        endcase end
    endfunction
    reg [5:0] q_cursor;
    reg [7:0] header_data;
    reg header_valid, header_last, header_done;
    wire header_ce = !header_valid || m_ready;
    reg [511:0] lookup_bytes;
    reg [5:0] lookup_bank;
    reg lookup_valid, lookup_last;
    wire lookup_ce = !lookup_valid || header_ce;
    assign m_valid = (state == HEADER && header_valid) || (state == EOI) || (state==RESTART) ||
        (state == SCAN && s_valid && s_bytes != 0);
    assign m_data = state == HEADER ?
        {120'd0, header_data} : (state == EOI ? {112'd0, 16'hd9ff} :
        state==RESTART?{112'd0,5'b11010,restart_index,8'hff}:s_data);
    assign m_bytes = state == HEADER ? 5'd1 : ((state == EOI || state==RESTART) ? 5'd2 : s_bytes);
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
            lookup_dri<=0;lookup_dri_data<=0;restart_index<=0;remaining_mcus<=0;
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
                restart_index<=0;
                remaining_mcus<=(frame_width>>(frame_gray?3:4))*(frame_height>>3);
            end else if (state == HEADER) begin
                // Each 32-byte segment is looked up first, then the registered bank
                // selects one candidate. Both elastic stages hold while stalled.
                if (header_ce) begin
                    header_valid <= lookup_valid;
                    if (lookup_valid) begin
                        header_data <= lookup_dri?lookup_dri_data:lookup_bytes[lookup_bank*8+:8];
                        header_last <= lookup_last;
                    end
                end
                if (lookup_ce) begin
                    lookup_valid <= !header_done;
                    if (!header_done) begin
                        lookup_bytes <= header_lookup(
                            rom_index[4:0], frame_width, frame_height, q_read_data
                        );
                        lookup_bank <= {!frame_gray, rom_index[9:5]};
                        lookup_dri<=dri_byte;lookup_dri_data<=dri_data(index-dri_offset);
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
            end else if (state == SCAN && s_valid && s_ready && s_frame_end) begin
                if(RESTART_MCUS!=0 && remaining_mcus>RESTART_MCUS) begin
                    remaining_mcus<=remaining_mcus-RESTART_MCUS;state<=RESTART;
                end else state<=EOI;
            end
            else if(state==RESTART && m_ready) begin restart_index<=restart_index+1'b1;state<=SCAN;end
            else if (state == EOI && m_ready) state <= IDLE;
        end
    end
endmodule
