// Portable 32-bit transport framing. Each payload beat is one tagged packet;
// descriptors are separate seven-word packets. Low byte is transmitted first.
module mjpeg_packetizer (
    input clk,
    input rst_n,
    input [127:0] s_data,
    input [4:0] s_bytes,
    input s_first, s_last, s_valid,
    output s_ready,
    input [1:0] s_channel,
    input [31:0] s_frame_id,
    input desc_valid,
    output desc_ready,
    input [1:0] desc_channel,
    input [31:0] desc_frame_id, desc_length,
    input [63:0] desc_timestamp,
    input [15:0] desc_width, desc_height,
    input desc_gray,
    input [7:0] desc_status,
    output reg [31:0] m_data,
    output reg [2:0] m_bytes,
    output m_valid,
    input m_ready,
    output reg m_packet_last
);
    reg active, is_descriptor, prefer_descriptor;
    reg [2:0] word_index;
    reg [127:0] data;
    reg [4:0] bytes;
    reg first, last;
    reg [1:0] channel;
    reg [31:0] frame_id, length;
    reg [63:0] timestamp;
    reg [15:0] width, height;
    reg gray;
    reg [7:0] status;
    wire choose_descriptor = desc_valid && (prefer_descriptor || !s_valid);
    assign s_ready = !active && !choose_descriptor;
    assign desc_ready = !active && choose_descriptor;
    assign m_valid = active;
    reg [4:0] remaining;
    always @* begin
        m_data = 0;
        m_bytes = 4;
        m_packet_last = 0;
        remaining = 0;
        case (word_index)
            0:
            m_data = {
                16'h4d4a,
                4'd1,
                is_descriptor ? 2'd1 : 2'd0,
                channel,
                first,
                last,
                (!is_descriptor && bytes == 0),
                bytes
            };
            1: begin
                m_data = frame_id;
                if (!is_descriptor && bytes == 0) m_packet_last = 1;
            end
            default:
            if (is_descriptor) begin
                case (word_index)
                    2: m_data = timestamp[31:0];
                    3: m_data = timestamp[63:32];
                    4: m_data = length;
                    5: m_data = {height, width};
                    6: begin
                        m_data = {23'd0, gray, status};
                        m_packet_last = 1;
                    end
                    default: m_data = 0;
                endcase
            end else begin
                m_data = data[(word_index-2)*32+:32];
                remaining = bytes - (word_index - 2) * 4;
                if (remaining <= 4) begin
                    m_bytes = remaining[2:0];
                    m_packet_last = 1;
                end
            end
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 0;
            is_descriptor <= 0;
            prefer_descriptor <= 0;
            word_index <= 0;
            data <= 0;
            bytes <= 0;
            first <= 0;
            last <= 0;
            channel <= 0;
            frame_id <= 0;
            length <= 0;
            timestamp <= 0;
            width <= 0;
            height <= 0;
            gray <= 0;
            status <= 0;
        end else begin
            if (m_valid && m_ready) begin
                if (m_packet_last) begin
                    active <= 0;
                    word_index <= 0;
                end else word_index <= word_index + 1'b1;
            end
            if (s_valid && s_ready) begin
                active <= 1;
                is_descriptor <= 0;
                prefer_descriptor <= 1;
                word_index <= 0;
                data <= s_data;
                bytes <= s_bytes;
                first <= s_first;
                last <= s_last;
                channel <= s_channel;
                frame_id <= s_frame_id;
            end
            if (desc_valid && desc_ready) begin
                active <= 1;
                is_descriptor <= 1;
                prefer_descriptor <= 0;
                word_index <= 0;
                first <= 0;
                last <= 0;
                bytes <= 0;
                channel <= desc_channel;
                frame_id <= desc_frame_id;
                length <= desc_length;
                timestamp <= desc_timestamp;
                width <= desc_width;
                height <= desc_height;
                gray <= desc_gray;
                status <= desc_status;
            end
        end
    end
endmodule
