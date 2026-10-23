`timescale 1ns / 1ps
// Camera pixels -> independent JPEG -> telemetry and transport.
// C starts continuous capture; S stops after the current frame.
// Response: "MJBT", then fixed 5-byte records {LE32 word, flags}.
// flags[2:0]=valid bytes, flags[3]=packet_last. All other bits are zero.
// Periodic telemetry uses flags 0x80..0x85 and may appear between bus records.
module mjpeg_camera_engine #(
    parameter CLOCK_HZ = 50000000,
    CAMERA_WIDTH = 640,
    CAMERA_HEIGHT = 480,
    BOARD_CONTROL = 0,
    PREPROCESS_ENABLE = 0
) (
    input sys_clk,
    sys_rst_n,
    input [7:0] rx_data,
    input rx_valid,
    output reg [7:0] tx_data,
    output reg tx_valid,
    input tx_ready,
    output [3:0] led,
    output [31:0] compressed_fps,
    output fps_sample_valid,
    input [15:0] camera_pixel,
    input camera_valid,
    camera_sof,
    camera_eol,
    camera_eof,
    camera_abort,
    input camera_ready,
    input camera_admission_enabled,
    input camera_queue_pressure,
    input [255:0] camera_status,
    input [95:0] preprocess_status,
    output camera_take,
    output camera_admit,
    input run_requested,
    input [1:0] quality_requested,
    output reg [1:0] active_quality
);
    (* ASYNC_REG="TRUE" *) reg [2:0] reset_pipe = 0;
    always @(posedge sys_clk or negedge sys_rst_n)
        if (!sys_rst_n) reset_pipe <= 0;
        else reset_pipe <= {reset_pipe[1:0], 1'b1};
    wire rst_n = reset_pipe[2];

    localparam IDLE=0,DIM=1,MODE=2,QREAD=3,QVALUE=4,QRECIP=5,
               TABLES=6,PSEND=7,WAIT_DESC=8,FINISH=9;
    reg [3:0] state;
    reg [ 6:0] q_index;
    reg done, error_seen, stop_requested, command_pending;
    reg [1:0] loading_quality;
    wire quality_pending = BOARD_CONTROL && quality_requested != active_quality;
    wire stop_now = BOARD_CONTROL ? !run_requested : (rx_valid && rx_data == "S");
    wire start;
    wire [15:0] width = CAMERA_WIDTH, height = CAMERA_HEIGHT;
    // Q60/Q75/Q85 tables, one 29-bit entry per {quality,index}.
    (* rom_style="block" *) reg [28:0] camera_quant[0:383];
    wire [15:0] source_pixel = camera_pixel;
    reg [28:0] q;
    initial begin
        $readmemh("data/board_test/camera_quant.mem", camera_quant);
    end
    always @(posedge sys_clk) begin
        if (state == QREAD) q <= camera_quant[{loading_quality, q_index}];
    end
    reg [2:0] cfg_cmd;
    reg [31:0] cfg_data;
    reg cfg_valid;
    wire cfg_ready, s_ready, busy, tables_ready, config_error;
    always @* begin
        cfg_valid = 1;
        cfg_cmd   = 0;
        cfg_data  = 0;
        case (state)
            DIM: begin
                cfg_cmd  = 0;
                cfg_data = {height, width};
            end
            MODE: begin
                cfg_cmd  = 1;
                cfg_data = 32'd1;
            end
            QVALUE: begin
                cfg_cmd  = 2;
                cfg_data = {17'd0, q[7:0], q_index};
            end
            QRECIP: begin
                cfg_cmd  = 3;
                cfg_data = {11'd0, q[28:8]};
            end
            default: cfg_valid = 0;
        endcase
    end
    wire [31:0] m_data;
    wire [ 2:0] m_bytes;
    wire m_valid, m_ready, m_packet_last;
    wire source_valid = state == PSEND && camera_valid;
    wire source_sof = camera_sof;
    wire source_eol = camera_eol;
    wire source_eof = camera_eof;
    assign camera_take = state == PSEND && s_ready;
    assign camera_admit = state == PSEND && tables_ready && camera_ready && !busy &&
                        !stop_requested && !stop_now && !quality_pending;
    mjpeg_synth_top #(
        .CHANNELS(1),
        .MAX_WIDTH(CAMERA_WIDTH),
        .COALESCE(1),
        .RESTART_MCUS(0)
    ) codec (
        .clk(sys_clk),
        .rst_n(rst_n),
        .cfg_cmd(cfg_cmd),
        .cfg_channel(2'd0),
        .cfg_data(cfg_data),
        .cfg_valid(cfg_valid),
        .cfg_ready(cfg_ready),
        .s_data(source_pixel),
        .s_valid(source_valid),
        .s_ready(s_ready),
        .s_sof(source_sof),
        .s_eol(source_eol),
        .s_eof(source_eof),
        .s_abort(camera_abort),
        .m_data(m_data),
        .m_bytes(m_bytes),
        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_packet_last(m_packet_last),
        .busy(busy),
        .tables_ready(tables_ready),
        .config_error(config_error)
    );

    // The byte transport stalls this boundary; JPEG bytes are never substituted.
    reg [39:0] record;
    reg [2:0] remaining, preamble;
    reg [2:0] packet_index;
    reg descriptor;
    reg telemetry_pending, telemetry_active;
    reg timing_pending, timing_active;
    reg camera_pending, camera_active;
    reg [3:0] camera_index;
    reg [255:0] camera_pending_data, camera_active_data;
    reg [95:0] preprocess_pending_data, preprocess_active_data;
    reg end_pending;
    assign m_ready=(state!=IDLE) && preamble==0 && remaining==0 &&
                   !telemetry_active && !telemetry_pending && !timing_active && !timing_pending &&
                   !camera_active && !camera_pending;
    wire word_taken = m_valid && m_ready;
    wire descriptor_done = word_taken && m_packet_last && descriptor;
    wire input_frame = source_valid && s_ready && source_sof;
    wire success_frame = descriptor_done && m_data[7:0] == 0;
    wire failed_frame = descriptor_done && m_data[7:0] != 0;
    wire [31:0] fps_window_id, input_fps, failed_fps, total_compressed;
    frame_rate_meter #(
        .CLOCK_HZ(CLOCK_HZ)
    ) meter (
        .clk(sys_clk),
        .rst_n(rst_n),
        .input_frame(input_frame),
        .success_frame(success_frame),
        .failed_frame(failed_frame),
        .sample_valid(fps_sample_valid),
        .window_id(fps_window_id),
        .input_fps(input_fps),
        .compressed_fps(compressed_fps),
        .failed_fps(failed_fps),
        .total_compressed(total_compressed)
    );
    assign start=(state==IDLE) && (BOARD_CONTROL?run_requested:command_pending) && remaining==0 && preamble==0 &&
                 !telemetry_active && !telemetry_pending && !timing_active && !timing_pending &&
                 !camera_active && !camera_pending && !end_pending && tx_ready;
    reg [2:0] telemetry_index;
    reg [31:0] pending_window, pending_input, pending_fps, pending_failed, pending_total;
    reg [31:0] active_window, active_input, active_fps, active_failed, active_total;
    reg [31:0] telemetry_data;
    always @* begin
        case (telemetry_index)
            0: telemetry_data = 32'h31535046;  // little-endian ASCII FPS1
            1: telemetry_data = active_window;
            2: telemetry_data = active_input;
            3: telemetry_data = active_fps;
            4: telemetry_data = active_failed;
            5: telemetry_data = active_total;
            default: telemetry_data = 0;
        endcase
    end
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            telemetry_pending <= 0;
            telemetry_active <= 0;
            telemetry_index <= 0;
            pending_window <= 0;
            pending_input <= 0;
            pending_fps <= 0;
            pending_failed <= 0;
            pending_total <= 0;
            active_window <= 0;
            active_input <= 0;
            active_fps <= 0;
            active_failed <= 0;
            active_total <= 0;
        end else begin
            if(!telemetry_active && !timing_active && !camera_active && telemetry_pending && remaining==0 && preamble==0 && !start) begin
                telemetry_active <= 1;
                telemetry_pending <= 0;
                telemetry_index <= 0;
                active_window <= pending_window;
                active_input <= pending_input;
                active_fps <= pending_fps;
                active_failed <= pending_failed;
                active_total <= pending_total;
            end
            if (telemetry_active && remaining == 0) begin
                if (telemetry_index == 5) begin
                    telemetry_active <= 0;
                    telemetry_index  <= 0;
                end else telemetry_index <= telemetry_index + 1'b1;
            end
            // If USB blocks longer than one second, retain the newest unsent
            // snapshot; an active six-record snapshot is never overwritten.
            if (fps_sample_valid) begin
                telemetry_pending <= 1;
                pending_window <= fps_window_id;
                pending_input <= input_fps;
                pending_fps <= compressed_fps;
                pending_failed <= failed_fps;
                pending_total <= total_compressed;
            end
        end
    end
    // Frame timings include transport backpressure. They do not measure an
    // isolated encoder running into an always-ready output sink.
    reg [31:0]
        timebase,
        frame_start_tick,
        feed_ticks,
        jpeg_ticks,
        input_wait,
        output_wait,
        timing_frame_id;
    reg frame_measured, last_payload;
    reg [2:0] timing_index;
    reg [31:0]
        report_id, report_feed, report_jpeg, report_total, report_input_wait, report_output_wait;
    reg [31:0] timing_data;
    always @* begin
        case (timing_index)
            0: timing_data = 32'h314d4954;  // TIM1
            1: timing_data = report_id;
            2: timing_data = report_feed;
            3: timing_data = report_jpeg;
            4: timing_data = report_total;
            5: timing_data = report_input_wait;
            6: timing_data = report_output_wait;
            default: timing_data = 0;
        endcase
    end
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            timebase <= 0;
            frame_start_tick <= 0;
            feed_ticks <= 0;
            jpeg_ticks <= 0;
            input_wait <= 0;
            output_wait <= 0;
            timing_frame_id <= 0;
            frame_measured <= 0;
            last_payload <= 0;
            timing_pending <= 0;
            timing_active <= 0;
            timing_index <= 0;
            report_id <= 0;
            report_feed <= 0;
            report_jpeg <= 0;
            report_total <= 0;
            report_input_wait <= 0;
            report_output_wait <= 0;
        end else begin
            timebase <= timebase + 1'b1;
            if (input_frame) begin
                frame_start_tick <= timebase;
                feed_ticks <= 0;
                jpeg_ticks <= 0;
                input_wait <= 0;
                output_wait <= 0;
                frame_measured <= 1'b1;
            end
            if (frame_measured) begin
                if (source_valid && !s_ready) input_wait <= input_wait + 1'b1;
                if (m_valid && !m_ready) output_wait <= output_wait + 1'b1;
                if (source_valid && s_ready && source_eof)
                    feed_ticks <= timebase - frame_start_tick;
                if (word_taken && m_packet_last && !descriptor && last_payload)
                    jpeg_ticks <= timebase - frame_start_tick;
            end
            if (word_taken && packet_index == 0) last_payload <= m_data[11:10] == 0 && m_data[6];
            if (word_taken && packet_index == 1 && descriptor) timing_frame_id <= m_data;
            if (descriptor_done && frame_measured) begin
                frame_measured <= 0;
                timing_pending <= m_data[7:0] == 0;
                report_id <= timing_frame_id;
                report_feed <= feed_ticks;
                report_jpeg <= jpeg_ticks;
                report_total <= timebase - frame_start_tick;
                report_input_wait <= input_wait;
                report_output_wait <= output_wait;
            end
            if(!timing_active && timing_pending && remaining==0 && preamble==0 &&
               !telemetry_active && !telemetry_pending && !camera_active && !start) begin
                timing_active  <= 1;
                timing_pending <= 0;
                timing_index   <= 0;
            end
            if (timing_active && remaining == 0) begin
                if (timing_index == 6) begin
                    timing_active <= 0;
                    timing_index  <= 0;
                end else timing_index <= timing_index + 1'b1;
            end
        end
    end
    // Status also flows while idle or initialization fails; no camera pixels
    // are required to read chip ID, clocks, overflow and admission counters.
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            camera_pending <= 0;
            camera_active <= 0;
            camera_index <= 0;
            camera_pending_data <= 0;
            camera_active_data <= 0;
            preprocess_pending_data <= 0;
            preprocess_active_data <= 0;
        end else begin
            if (fps_sample_valid) begin
                camera_pending <= 1;
                camera_pending_data <= {
                    camera_status[255:32], camera_status[31:7], state != IDLE, camera_status[5:0]
                };
                if (PREPROCESS_ENABLE) preprocess_pending_data <= preprocess_status;
            end
            if(!camera_active && camera_pending && remaining==0 && preamble==0 &&
               !telemetry_active && !telemetry_pending && !timing_active && !timing_pending && !start) begin
                camera_active <= 1;
                camera_pending <= 0;
                camera_index <= 0;
                camera_active_data <= camera_pending_data;
                if (PREPROCESS_ENABLE) preprocess_active_data <= preprocess_pending_data;
            end
            if (camera_active && remaining == 0) begin
                if (camera_index == (PREPROCESS_ENABLE ? 12 : 8)) begin
                    camera_active <= 0;
                    camera_index  <= 0;
                end else camera_index <= camera_index + 1'b1;
            end
        end
    end
    always @* begin
        tx_valid = 0;
        tx_data  = 0;
        if (preamble != 0) begin
            tx_valid = 1;
            case (preamble)
                4: tx_data = "M";
                3: tx_data = "J";
                2: tx_data = "B";
                1: tx_data = "T";
                default: tx_data = 0;
            endcase
        end else if (remaining != 0) begin
            tx_valid = 1;
            tx_data  = record[7:0];
        end
    end
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            record <= 0;
            remaining <= 0;
            preamble <= 0;
            packet_index <= 0;
            descriptor <= 0;
            end_pending <= 0;
        end else begin
            if (start) begin
                preamble <= 4;
                packet_index <= 0;
                descriptor <= 0;
            end
            if (tx_valid && tx_ready) begin
                if (preamble != 0) preamble <= preamble - 1'b1;
                else begin
                    remaining <= remaining - 1'b1;
                    record <= {8'd0, record[39:8]};
                end
            end
            if (word_taken) begin
                record <= {4'd0, m_packet_last, m_bytes, m_data};
                remaining <= 5;
                if (packet_index == 0) descriptor <= m_data[11:10] == 1;
                packet_index <= m_packet_last ? 0 : packet_index + 1'b1;
            end
            if (telemetry_active && remaining == 0) begin
                record <= {(8'h80 + {5'd0, telemetry_index}), telemetry_data};
                remaining <= 5;
            end
            if (timing_active && remaining == 0) begin
                record <= {(8'h90 + {5'd0, timing_index}), timing_data};
                remaining <= 5;
            end
            if (camera_active && remaining == 0) begin
                record <= {
                    (8'hb0 + {4'd0, camera_index}),
                    camera_index==0?32'h314d4143:
                    camera_index==9?32'h31505250:camera_index>9?preprocess_active_data[(camera_index-10)*32+:32]:
                    camera_active_data[(camera_index-1)*32+:32]
                };
                remaining <= 5;
            end
            if(state==FINISH && remaining==0 && tx_ready && !m_valid && !busy &&
               !telemetry_active && !telemetry_pending && !timing_active && !timing_pending && !camera_active && !camera_pending)
                end_pending <= 1'b1;
            if(end_pending && remaining==0 && !telemetry_active && !telemetry_pending && !timing_active && !timing_pending && !camera_active && !camera_pending) begin
                record <= {8'ha0, 32'h31444e45};
                remaining <= 5;
                end_pending <= 0;  // END1
            end
        end
    end
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            q_index <= 0;
            done <= 0;
            error_seen <= 0;
            stop_requested <= 0;
            command_pending <= 0;
            active_quality <= 2;
            loading_quality <= 2;
        end else begin
            if(rx_valid && state==IDLE && rx_data=="C") command_pending <= 1;
            if (stop_now && state != IDLE) stop_requested <= 1;
            if (config_error && (state == PSEND || state == WAIT_DESC)) error_seen <= 1;
            if (descriptor_done && m_data[7:0] != 0) error_seen <= 1;
            case (state)
                IDLE:
                if (start) begin
                    state <= DIM;
                    done <= 0;
                    error_seen <= 0;
                    stop_requested <= 0;
                    command_pending <= 0;
                    loading_quality <= BOARD_CONTROL ? quality_requested : 2'd2;
                end
                DIM: if (cfg_ready) state <= MODE;
                MODE:
                if (cfg_ready) begin
                    state   <= QREAD;
                    q_index <= 0;
                end
                QREAD: state <= QVALUE;
                QVALUE: if (cfg_ready) state <= QRECIP;
                QRECIP:
                if (cfg_ready) begin
                    if (q_index == 127) state <= TABLES;
                    else begin
                        q_index <= q_index + 1'b1;
                        state   <= QREAD;
                    end
                end
                TABLES:
                if (stop_requested || stop_now) state <= FINISH;
                else if (tables_ready && !config_error && camera_ready) begin
                    active_quality <= loading_quality;
                    if (BOARD_CONTROL && quality_requested != loading_quality) begin
                        loading_quality <= quality_requested;
                        q_index <= 0;
                        state <= QREAD;
                    end else begin
                        state <= PSEND;
                    end
                end
                PSEND:
                if (camera_abort && busy) state <= WAIT_DESC;
                else if(!busy && !camera_valid && !camera_status[2] && !camera_admission_enabled &&
                        (stop_requested || stop_now || quality_pending)) begin
                    if (stop_requested || stop_now) state <= FINISH;
                    else begin
                        loading_quality <= quality_requested;
                        q_index <= 0;
                        state <= QREAD;
                    end
                end else if (source_valid && s_ready) begin
                    if (source_eof) state <= WAIT_DESC;
                end
                WAIT_DESC:
                if (descriptor_done) begin
                    if (stop_requested || stop_now) state <= FINISH;
                    else state <= PSEND;
                end
                FINISH:
                if (remaining==0 && tx_ready && !m_valid && !busy && !telemetry_active && !telemetry_pending &&
                           !timing_active && !timing_pending && !camera_active && !camera_pending) begin
                    state <= IDLE;
                    done  <= 1;
                end
                default: state <= IDLE;
            endcase
        end
    end
    assign led = {error_seen, done, (state != IDLE), tables_ready};
endmodule
