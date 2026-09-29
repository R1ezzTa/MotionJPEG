// One continuous JPEG channel. Frame completion includes payload acceptance
// and queuing its descriptor. Abort emits a zero-byte end token; cached
// quantization entries are replayed after resetting the JPEG core.
module mjpeg_channel #(
    parameter MAX_WIDTH = 1920, RESTART_MCUS=0, SPATIAL_SKIP=0, SPATIAL_THRESHOLD=0, SPATIAL_DDR=0,SPATIAL_ADAPTIVE=0
) (
    output mem_cmd_valid,mem_cmd_write,input mem_cmd_ready,
    output [27:0] mem_cmd_addr,output [13:0] mem_cmd_bytes,
    output [127:0] mem_w_data,output [15:0] mem_w_keep,
    output mem_w_valid,mem_w_last,input mem_w_ready,
    input [127:0] mem_r_data,input mem_r_valid,mem_r_last,output mem_r_ready,
    input mem_done,mem_error,output mem_fault,
    input clk,
    input rst_n,
    input enable,
    input [15:0] cfg_width, cfg_height,
    input cfg_gray,
    input [7:0] cfg_skip_threshold,
    input cfg_skip_adaptive,input cfg_skip_pressure,
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
    // An asynchronous reset must come from one register. Decoding the binary
    // WRITE_TABLE (11) -> NORMAL (00) transition can briefly decode RESET_CORE
    // (01) in hardware and erase the table that has just been restored.
    reg core_reset;
    reg [6:0] restore_index;
    reg [28:0] restore_data;
    reg [28:0] table_cache[0:127];  // synthesis ram_style=bram
    reg [127:0] cache_valid;
    reg inflight, terminated, aborted, output_started, descriptor_pending;
    reg [31:0] next_id, frame_id, total_bytes;
    reg [63:0] timestamp;
    reg [15:0] frame_width, frame_height;
    reg frame_gray;
    reg [7:0] frame_skip_threshold;
    reg frame_skip_adaptive;
    reg [7:0] errors;
    wire core_rst_n = rst_n && !core_reset;
    wire core_q_ready, core_q_valid, core_tables_ready;
    wire core_s_ready, core_busy, protocol_error, coefficient_error;
    wire [127:0] core_data;
    wire [4:0] core_bytes;
    wire core_valid, core_last;
    wire skip_recovering,skip_mem_active;
    wire replay = (recovery == WRITE_TABLE);
    assign cfg_q_ready = core_q_ready && !inflight && !skip_mem_active && !skip_recovering && (recovery == NORMAL);
    assign core_q_valid = replay || (cfg_q_valid && cfg_q_ready);
    assign tables_ready = core_tables_ready && (recovery == NORMAL);
    assign busy = inflight || (recovery != NORMAL) || skip_recovering || skip_mem_active;
    wire abort_now = (s_abort || mem_fault) && inflight && !terminated && !aborted;
    wire input_allowed = enable && !skip_recovering && (inflight || !skip_mem_active) && (recovery == NORMAL) && !terminated && !aborted && !abort_now;
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
    wire [127:0] raw_core_data;
    wire [4:0] raw_core_bytes;
    wire raw_core_valid,raw_core_ready,raw_core_last;
    generate if(SPATIAL_SKIP && SPATIAL_DDR) begin: ddr_spatial_transport
        jpeg_spatial_skip_ddr #(.THRESHOLD_ENABLE(SPATIAL_THRESHOLD),.ADAPTIVE_ENABLE(SPATIAL_ADAPTIVE)) skip(
            .clk(clk),.rst_n(rst_n),.abort(abort_now || recovery==RESET_CORE),
            .recovering(skip_recovering),
            .invalidate(core_q_valid && core_q_ready),
            .cfg_threshold(frame_skip_threshold),.cfg_adaptive(frame_skip_adaptive),.input_pressure(cfg_skip_pressure),.cfg_q_valid(core_q_valid && core_q_ready),
            .cfg_q_addr(replay ? restore_index : cfg_q_addr),.cfg_q_value(replay ? restore_data[7:0] : cfg_q_value),
            .frame_id(frame_id),.width(cfg_width),.height(cfg_height),.gray(cfg_gray),
            .s_data(raw_core_data),.s_bytes(raw_core_bytes),.s_last(raw_core_last),
            .s_valid(raw_core_valid),.s_ready(raw_core_ready),
            .m_data(core_data),.m_bytes(core_bytes),.m_last(core_last),.m_valid(core_valid),
            .m_ready(m_ready && inflight && !terminated && !aborted && !abort_now),
        .cmd_valid(mem_cmd_valid),.cmd_write(mem_cmd_write),.cmd_ready(mem_cmd_ready),.cmd_addr(mem_cmd_addr),
        .cmd_bytes(mem_cmd_bytes),.w_data(mem_w_data),.w_keep(mem_w_keep),.w_valid(mem_w_valid),
        .w_last(mem_w_last),.w_ready(mem_w_ready),.r_data(mem_r_data),.r_valid(mem_r_valid),
        .r_last(mem_r_last),.r_ready(mem_r_ready),.mem_done(mem_done),.mem_error(mem_error),
            .mem_fault(mem_fault),.mem_active(skip_mem_active));
    end else if(SPATIAL_SKIP) begin: spatial_transport
        jpeg_spatial_skip #(.THRESHOLD_ENABLE(SPATIAL_THRESHOLD)) skip(
            .clk(clk),.rst_n(core_rst_n),.invalidate(core_q_valid && core_q_ready),
            .cfg_threshold(frame_skip_threshold),.cfg_q_valid(core_q_valid && core_q_ready),
            .cfg_q_addr(replay ? restore_index : cfg_q_addr),.cfg_q_value(replay ? restore_data[7:0] : cfg_q_value),
            .frame_id(frame_id),.width(cfg_width),.height(cfg_height),.gray(cfg_gray),
            .s_data(raw_core_data),.s_bytes(raw_core_bytes),.s_last(raw_core_last),
            .s_valid(raw_core_valid),.s_ready(raw_core_ready),
            .m_data(core_data),.m_bytes(core_bytes),.m_last(core_last),.m_valid(core_valid),
            .m_ready(m_ready && inflight && !terminated && !aborted && !abort_now));
    end else begin: independent_transport
        assign core_data=raw_core_data;assign core_bytes=raw_core_bytes;
        assign core_last=raw_core_last;assign core_valid=raw_core_valid;
        assign raw_core_ready=m_ready && inflight && !terminated && !aborted && !abort_now;
    end endgenerate
    generate if(!SPATIAL_DDR || !SPATIAL_SKIP) begin: no_ddr
        assign mem_cmd_valid=0;assign mem_cmd_write=0;assign mem_cmd_addr=0;assign mem_cmd_bytes=0;
        assign mem_w_data=0;assign mem_w_keep=0;assign mem_w_valid=0;assign mem_w_last=0;
        assign mem_r_ready=0;assign mem_fault=0;assign skip_recovering=0;assign skip_mem_active=0;
    end endgenerate
    jpeg_encoder #(
        .MAX_WIDTH(MAX_WIDTH),.RESTART_MCUS(RESTART_MCUS)
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
        .m_data           (raw_core_data),
        .m_bytes          (raw_core_bytes),
        .m_valid          (raw_core_valid),
        .m_ready          (raw_core_ready),
        .m_last           (raw_core_last),
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
            core_reset <= 0;
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
            frame_skip_threshold <= 0;
            frame_skip_adaptive <= 0;
            errors <= 0;
        end else begin
            if (cfg_q_valid && cfg_q_ready && cfg_q_value != 0 && cfg_q_recip != 0)
                cache_valid[cfg_q_addr] <= 1;
            case (recovery)
                RESET_CORE: begin
                    core_reset <= 0;
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
                frame_skip_threshold <= cfg_skip_threshold;
                frame_skip_adaptive <= SPATIAL_ADAPTIVE?cfg_skip_adaptive:1'b0;
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
                core_reset <= 1;
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
