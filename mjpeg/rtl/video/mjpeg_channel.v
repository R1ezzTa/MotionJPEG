// One continuous JPEG channel. Frame completion includes payload acceptance
// and queuing its descriptor. Abort emits a zero-byte end token; cached
// quantization entries are replayed after resetting the JPEG core.
module mjpeg_channel #(
    parameter MAX_WIDTH = 1920
) (
    input clk,
    input rst_n,
    input enable,
    input [15:0] cfg_width, cfg_height,
    input cfg_gray,
    input cfg_q_valid,
    output cfg_q_ready,
    input [6:0] cfg_q_addr,
    input [7:0] cfg_q_value,
    input [20:0] cfg_q_recip,
    output tables_ready, config_error,
    input [15:0] s_data,
    input s_valid,
    output s_ready,
    input s_sof, s_eol, s_eof, s_abort,
    input [63:0] s_timestamp,
    output [127:0] m_data,
    output [4:0] m_bytes,
    output m_first, m_last, m_valid,
    input m_ready,
    output [31:0] m_frame_id,
    input frame_done,
    output desc_valid,
    input desc_ready,
    output [31:0] desc_frame_id, desc_length,
    output [63:0] desc_timestamp,
    output [15:0] desc_width, desc_height,
    output desc_gray,
    output [7:0] desc_status,
    output busy
);
    localparam NORMAL = 2'd0, RESET_CORE = 2'd1, READ_TABLE = 2'd2, WRITE_TABLE = 2'd3;
    reg [1:0] recovery;
    reg [6:0] restore_index;
    reg [28:0] restore_data;
    reg [28:0] table_cache[0:127];  // synthesis ram_style=bram
    reg [127:0] cache_valid;
    reg inflight, terminated, aborted, output_started, descriptor_pending;
    reg [31:0] next_id, frame_id, total_bytes;
    reg [63:0] timestamp;
    reg [15:0] frame_width, frame_height;
    reg frame_gray;
    reg [7:0] errors;
    wire core_rst_n = rst_n && (recovery != RESET_CORE);
    wire core_q_ready, core_q_valid, core_tables_ready;
    wire core_s_ready, core_busy, protocol_error, coefficient_error;
    wire [127:0] core_data;
    wire [4:0] core_bytes;
    wire core_valid, core_last;
    wire replay = (recovery == WRITE_TABLE);
    assign cfg_q_ready = core_q_ready && !inflight && (recovery == NORMAL);
    assign core_q_valid = replay || (cfg_q_valid && cfg_q_ready);
    assign tables_ready = core_tables_ready && (recovery == NORMAL);
    assign busy = inflight || (recovery != NORMAL);
    wire abort_now = s_abort && inflight && !terminated && !aborted;
    wire input_allowed = enable && (recovery == NORMAL) && !terminated && !aborted && !abort_now;
    assign s_ready = core_s_ready && input_allowed;
    wire first_pixel = s_valid && s_ready && !inflight;
    assign m_valid = inflight && !terminated && !abort_now && (aborted || core_valid);
    assign m_data = aborted ? 128'd0 : core_data;
    assign m_bytes = aborted ? 5'd0 : core_bytes;
    assign m_last = aborted || core_last;
    assign m_first = !output_started;
    assign m_frame_id = frame_id;
    wire take_output = m_valid && m_ready;
    assign desc_valid = descriptor_pending;
    assign desc_frame_id = frame_id;
    assign desc_timestamp = timestamp;
    assign desc_length = total_bytes;
    assign desc_width = frame_width;
    assign desc_height = frame_height;
    assign desc_gray = frame_gray;
    assign desc_status = errors;
    jpeg_encoder #(
        .MAX_WIDTH(MAX_WIDTH)
    ) core (
        .clk              (clk),
        .rst_n            (core_rst_n),
        .cfg_width        (cfg_width),
        .cfg_height       (cfg_height),
        .cfg_gray         (cfg_gray),
        .cfg_q_valid      (core_q_valid),
        .cfg_q_ready      (core_q_ready),
        .cfg_q_addr       (replay ? restore_index : cfg_q_addr),
        .cfg_q_value      (replay ? restore_data[7:0] : cfg_q_value),
        .cfg_q_recip      (replay ? restore_data[28:8] : cfg_q_recip),
        .tables_ready     (core_tables_ready),
        .config_error     (config_error),
        .s_data           (s_data),
        .s_valid          (s_valid && input_allowed),
        .s_ready          (core_s_ready),
        .s_sof            (s_sof),
        .s_eol            (s_eol),
        .s_eof            (s_eof),
        .m_data           (core_data),
        .m_bytes          (core_bytes),
        .m_valid          (core_valid),
        .m_ready          (m_ready && inflight && !terminated && !aborted && !abort_now),
        .m_last           (core_last),
        .busy             (core_busy),
        .protocol_error   (protocol_error),
        .coefficient_error(coefficient_error)
    );
    always @(posedge clk) begin
        if (cfg_q_valid && cfg_q_ready && cfg_q_value != 0 && cfg_q_recip != 0)
            table_cache[cfg_q_addr] <= {cfg_q_recip, cfg_q_value};
        if (recovery == READ_TABLE) restore_data <= table_cache[restore_index];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recovery <= NORMAL;
            restore_index <= 0;
            cache_valid <= 0;
            inflight <= 0;
            terminated <= 0;
            aborted <= 0;
            output_started <= 0;
            descriptor_pending <= 0;
            next_id <= 0;
            frame_id <= 0;
            total_bytes <= 0;
            timestamp <= 0;
            frame_width <= 0;
            frame_height <= 0;
            frame_gray <= 0;
            errors <= 0;
        end else begin
            if (cfg_q_valid && cfg_q_ready && cfg_q_value != 0 && cfg_q_recip != 0)
                cache_valid[cfg_q_addr] <= 1;
            case (recovery)
                RESET_CORE: begin
                    restore_index <= 0;
                    recovery <= (&cache_valid) ? READ_TABLE : NORMAL;
                end
                READ_TABLE: recovery <= WRITE_TABLE;
                WRITE_TABLE:
                if (core_q_ready) begin
                    if (restore_index == 127) recovery <= NORMAL;
                    else begin
                        restore_index <= restore_index + 1'b1;
                        recovery <= READ_TABLE;
                    end
                end
                default: begin
                end
            endcase
            if (first_pixel) begin
                inflight <= 1;
                terminated <= 0;
                aborted <= 0;
                output_started <= 0;
                descriptor_pending <= 0;
                frame_id <= next_id;
                next_id <= next_id + 1'b1;
                timestamp <= s_timestamp;
                total_bytes <= 0;
                frame_width <= cfg_width;
                frame_height <= cfg_height;
                frame_gray <= cfg_gray;
                errors <= 0;
            end
            if (take_output) begin
                output_started <= 1;
                total_bytes <= total_bytes + m_bytes;
                if (m_last) begin
                    terminated <= 1;
                    if (!aborted)
                        errors <= {4'd0, config_error, coefficient_error, protocol_error, 1'b0};
                end
            end
            if (abort_now) begin
                aborted <= 1;
                recovery <= RESET_CORE;
                errors <= {4'd0, config_error, coefficient_error, protocol_error, 1'b1};
            end
            if (frame_done && inflight && terminated) descriptor_pending <= 1;
            if (desc_valid && desc_ready) begin
                descriptor_pending <= 0;
                inflight <= 0;
                terminated <= 0;
                aborted <= 0;
            end
        end
    end
endmodule
