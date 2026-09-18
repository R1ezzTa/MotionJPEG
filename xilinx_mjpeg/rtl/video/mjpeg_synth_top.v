// Two pixel lanes keep independent capture streams parallel while fitting
// the package IO budget. Configuration and transport use separate 32-bit buses.
module mjpeg_synth_top #(
    parameter CHANNELS = 2,
    MAX_WIDTH = 1920
) (
    input clk,
    input rst_n,
    input [2:0] cfg_cmd,
    input [1:0] cfg_channel,
    input [31:0] cfg_data,
    input cfg_valid,
    output cfg_ready,
    input [CHANNELS*16-1:0] s_data,
    input [CHANNELS-1:0] s_valid,
    output [CHANNELS-1:0] s_ready,
    input [CHANNELS-1:0] s_sof, s_eol, s_eof, s_abort,
    output [31:0] m_data,
    output [2:0] m_bytes,
    output m_valid,
    input m_ready,
    output m_packet_last,
    output [CHANNELS-1:0] busy, tables_ready, config_error
);
    reg [CHANNELS*16-1:0] widths, heights;
    reg [CHANNELS-1:0] enabled, gray;
    reg [CHANNELS*7-1:0] q_addr;
    reg [CHANNELS*8-1:0] q_value;
    wire [CHANNELS-1:0] q_valid, q_ready;
    wire [CHANNELS*21-1:0] q_recip;
    wire [CHANNELS-1:0] config_block, pixel_ready;
    assign s_ready = pixel_ready & ~config_block;
    wire channel_ok = cfg_channel < CHANNELS;
    assign cfg_ready = channel_ok && !busy[cfg_channel] &&
        ((cfg_cmd <= 2) || (cfg_cmd == 3 && q_ready[cfg_channel]));
    reg [63:0] clock_ticks;
    wire [CHANNELS*64-1:0] timestamps;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            widths <= 0;
            heights <= 0;
            enabled <= 0;
            gray <= 0;
            q_addr <= 0;
            q_value <= 0;
            clock_ticks <= 0;
        end else begin
            clock_ticks <= clock_ticks + 1'b1;
            if (cfg_valid && cfg_ready)
                case (cfg_cmd)
                    0: begin
                        widths[cfg_channel*16+:16] <= cfg_data[15:0];
                        heights[cfg_channel*16+:16] <= cfg_data[31:16];
                    end
                    1: begin
                        enabled[cfg_channel] <= cfg_data[0];
                        gray[cfg_channel] <= cfg_data[1];
                    end
                    2: begin
                        q_addr[cfg_channel*7+:7] <= cfg_data[6:0];
                        q_value[cfg_channel*8+:8] <= cfg_data[14:7];
                    end
                    default: begin
                    end
                endcase
        end
    end
    genvar c;
    generate
        for (c = 0; c < CHANNELS; c = c + 1) begin : config_lanes
            assign config_block[c] = cfg_valid && cfg_ready && cfg_channel == c;
            assign q_valid[c] = cfg_valid && cfg_ready && cfg_cmd == 3 && cfg_channel == c;
            assign q_recip[c*21+:21] = cfg_data[20:0];
            assign timestamps[c*64+:64] = clock_ticks;
        end
    endgenerate
    wire [127:0] payload;
    wire [4:0] payload_bytes;
    wire payload_first, payload_last, payload_valid, payload_ready;
    wire [1:0] payload_channel, descriptor_channel;
    wire [31:0] payload_id, descriptor_id, descriptor_length;
    wire descriptor_valid, descriptor_ready, descriptor_gray;
    wire [63:0] descriptor_timestamp;
    wire [15:0] descriptor_width, descriptor_height;
    wire [7:0] descriptor_status;
    mjpeg_encoder #(
        .CHANNELS (CHANNELS),
        .MAX_WIDTH(MAX_WIDTH)
    ) encoder (
        .clk           (clk),
        .rst_n         (rst_n),
        .enable        (enabled),
        .cfg_gray      (gray),
        .cfg_width     (widths),
        .cfg_height    (heights),
        .cfg_q_valid   (q_valid),
        .cfg_q_ready   (q_ready),
        .cfg_q_addr    (q_addr),
        .cfg_q_value   (q_value),
        .cfg_q_recip   (q_recip),
        .tables_ready  (tables_ready),
        .config_error  (config_error),
        .busy          (busy),
        .s_data        (s_data),
        .s_valid       (s_valid & ~config_block),
        .s_ready       (pixel_ready),
        .s_sof         (s_sof),
        .s_eol         (s_eol),
        .s_eof         (s_eof),
        .s_abort       (s_abort),
        .s_timestamp   (timestamps),
        .m_data        (payload),
        .m_bytes       (payload_bytes),
        .m_first       (payload_first),
        .m_last        (payload_last),
        .m_valid       (payload_valid),
        .m_ready       (payload_ready),
        .m_channel     (payload_channel),
        .m_frame_id    (payload_id),
        .desc_valid    (descriptor_valid),
        .desc_ready    (descriptor_ready),
        .desc_channel  (descriptor_channel),
        .desc_frame_id (descriptor_id),
        .desc_length   (descriptor_length),
        .desc_timestamp(descriptor_timestamp),
        .desc_width    (descriptor_width),
        .desc_height   (descriptor_height),
        .desc_gray     (descriptor_gray),
        .desc_status   (descriptor_status)
    );
    mjpeg_packetizer transport (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_data        (payload),
        .s_bytes       (payload_bytes),
        .s_first       (payload_first),
        .s_last        (payload_last),
        .s_valid       (payload_valid),
        .s_ready       (payload_ready),
        .s_channel     (payload_channel),
        .s_frame_id    (payload_id),
        .desc_valid    (descriptor_valid),
        .desc_ready    (descriptor_ready),
        .desc_channel  (descriptor_channel),
        .desc_frame_id (descriptor_id),
        .desc_length   (descriptor_length),
        .desc_timestamp(descriptor_timestamp),
        .desc_width    (descriptor_width),
        .desc_height   (descriptor_height),
        .desc_gray     (descriptor_gray),
        .desc_status   (descriptor_status),
        .m_data        (m_data),
        .m_bytes       (m_bytes),
        .m_valid       (m_valid),
        .m_ready       (m_ready),
        .m_packet_last (m_packet_last)
    );
endmodule
