// Continuous multi-channel MJPEG IP. All inputs are in clk domain; A must
// buffer capture data and honor ready, or signal abort for incomplete frames.
module mjpeg_encoder #(
    parameter CHANNELS = 2,
    MAX_WIDTH = 1920
) (
    input clk,
    input rst_n,
    input [CHANNELS-1:0] enable, cfg_gray,
    input [CHANNELS*16-1:0] cfg_width, cfg_height,
    input [CHANNELS-1:0] cfg_q_valid,
    output [CHANNELS-1:0] cfg_q_ready,
    input [CHANNELS*7-1:0] cfg_q_addr,
    input [CHANNELS*8-1:0] cfg_q_value,
    input [CHANNELS*21-1:0] cfg_q_recip,
    output [CHANNELS-1:0] tables_ready, config_error, busy,
    input [CHANNELS*16-1:0] s_data,
    input [CHANNELS-1:0] s_valid,
    output [CHANNELS-1:0] s_ready,
    input [CHANNELS-1:0] s_sof, s_eol, s_eof, s_abort,
    input [CHANNELS*64-1:0] s_timestamp,
    output [127:0] m_data,
    output [4:0] m_bytes,
    output m_first, m_last, m_valid,
    input m_ready,
    output [1:0] m_channel,
    output [31:0] m_frame_id,
    output desc_valid,
    input desc_ready,
    output [1:0] desc_channel,
    output [31:0] desc_frame_id, desc_length,
    output [63:0] desc_timestamp,
    output [15:0] desc_width, desc_height,
    output desc_gray,
    output [7:0] desc_status
);
    wire [CHANNELS*167-1:0] payloads;
    wire [CHANNELS*169-1:0] descriptors;
    wire [CHANNELS-1:0] payload_valid, payload_ready, descriptor_valid, descriptor_ready;
    wire [168:0] tagged_payload;
    wire [170:0] tagged_descriptor;
    genvar c;
    generate
        for (c = 0; c < CHANNELS; c = c + 1) begin : channels
            wire [127:0] data;
            wire [4:0] bytes;
            wire first, last;
            wire [166:0] local_payload;
            wire local_valid, local_ready;
            wire [31:0] frame_id, descriptor_id, length;
            wire [63:0] timestamp;
            wire [15:0] width, height;
            wire gray;
            wire [7:0] status;
            // Each core sees only its local registered occupancy as downstream ready.
            // Round-robin selection cannot propagate into either entropy pipeline.
            jpeg_stream_buffer #(
                .WIDTH(167)
            ) channel_output (
                .clk    (clk),
                .rst_n  (rst_n),
                .s_data ({frame_id, first, last, bytes, data}),
                .s_valid(local_valid),
                .s_ready(local_ready),
                .m_data (local_payload),
                .m_valid(payload_valid[c]),
                .m_ready(payload_ready[c])
            );
            assign payloads[c*167+:167] = local_payload;
            assign descriptors[c*169+:169] = {
                descriptor_id, timestamp, length, width, height, gray, status
            };
            mjpeg_channel #(
                .MAX_WIDTH(MAX_WIDTH)
            ) channel (
                .clk           (clk),
                .rst_n         (rst_n),
                .enable        (enable[c]),
                .cfg_width     (cfg_width[c*16+:16]),
                .cfg_height    (cfg_height[c*16+:16]),
                .cfg_gray      (cfg_gray[c]),
                .cfg_q_valid   (cfg_q_valid[c]),
                .cfg_q_ready   (cfg_q_ready[c]),
                .cfg_q_addr    (cfg_q_addr[c*7+:7]),
                .cfg_q_value   (cfg_q_value[c*8+:8]),
                .cfg_q_recip   (cfg_q_recip[c*21+:21]),
                .tables_ready  (tables_ready[c]),
                .config_error  (config_error[c]),
                .busy          (busy[c]),
                .s_data        (s_data[c*16+:16]),
                .s_valid       (s_valid[c]),
                .s_ready       (s_ready[c]),
                .s_sof         (s_sof[c]),
                .s_eol         (s_eol[c]),
                .s_eof         (s_eof[c]),
                .s_abort       (s_abort[c]),
                .s_timestamp   (s_timestamp[c*64+:64]),
                .m_data        (data),
                .m_bytes       (bytes),
                .m_first       (first),
                .m_last        (last),
                .m_frame_id    (frame_id),
                .m_valid       (local_valid),
                .m_ready       (local_ready),
                .frame_done    (m_valid && m_ready && m_last && m_channel == c),
                .desc_valid    (descriptor_valid[c]),
                .desc_ready    (descriptor_ready[c]),
                .desc_frame_id (descriptor_id),
                .desc_timestamp(timestamp),
                .desc_length   (length),
                .desc_width    (width),
                .desc_height   (height),
                .desc_gray     (gray),
                .desc_status   (status)
            );
        end
    endgenerate
    mjpeg_arbiter #(
        .CHANNELS(CHANNELS),
        .WIDTH   (167)
    ) payload_arbiter (
        .clk    (clk),
        .rst_n  (rst_n),
        .s_data (payloads),
        .s_valid(payload_valid),
        .s_ready(payload_ready),
        .m_data (tagged_payload),
        .m_valid(m_valid),
        .m_ready(m_ready)
    );
    assign {m_channel, m_frame_id, m_first, m_last, m_bytes, m_data} = tagged_payload;
    mjpeg_arbiter #(
        .CHANNELS(CHANNELS),
        .WIDTH   (169)
    ) descriptor_arbiter (
        .clk    (clk),
        .rst_n  (rst_n),
        .s_data (descriptors),
        .s_valid(descriptor_valid),
        .s_ready(descriptor_ready),
        .m_data (tagged_descriptor),
        .m_valid(desc_valid),
        .m_ready(desc_ready)
    );
    assign {desc_channel, desc_frame_id, desc_timestamp, desc_length, desc_width, desc_height,
            desc_gray, desc_status} = tagged_descriptor;
endmodule
