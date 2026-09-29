// Internal YUYV camera substitute -> existing MJPEG -> byte transport.
// G: nine small frames; C: continuous small frames; V/H/F: VGA/720p/1080p
// continuous colour ramp. S: stop after the current frame.
// Response: "MJBT", then fixed 5-byte records {LE32 word, flags}.
// flags[2:0]=valid bytes, flags[3]=packet_last. All other bits are zero.
// Periodic telemetry uses flags 0x80..0x85 and may appear between bus records.
module mjpeg_board_test_engine #(
    parameter CLOCK_HZ=50000000,VGA_WIDTH=640,VGA_HEIGHT=480,
    HD_WIDTH=1280,HD_HEIGHT=720,FHD_WIDTH=1920,FHD_HEIGHT=1080,SMALL_END=0,
    REAL_CAMERA=0,CAMERA_WIDTH=640,CAMERA_HEIGHT=480,BOARD_CONTROL=0,SPATIAL_SKIP=0,SPATIAL_THRESHOLD=0,SPATIAL_DDR=0,SPATIAL_ADAPTIVE=0,PREPROCESS_ENABLE=0
)(
    output mem_cmd_valid,mem_cmd_write,input mem_cmd_ready,
    output [27:0] mem_cmd_addr,output [13:0] mem_cmd_bytes,
    output [127:0] mem_w_data,output [15:0] mem_w_keep,
    output mem_w_valid,mem_w_last,input mem_w_ready,
    input [127:0] mem_r_data,input mem_r_valid,mem_r_last,output mem_r_ready,
    input mem_done,mem_error,output mem_fault,
    input sys_clk, sys_rst_n,
    input [7:0] rx_data, input rx_valid,
    output reg [7:0] tx_data, output reg tx_valid, input tx_ready,
    output [3:0] led,
    output [31:0] compressed_fps,output fps_sample_valid,
    input [15:0] camera_pixel,input camera_valid,camera_sof,camera_eol,camera_eof,camera_abort,
    input camera_ready,input camera_admission_enabled,input camera_queue_pressure,input [255:0] camera_status,input [95:0] preprocess_status,
    output camera_take,output camera_admit,
    input run_requested,input [1:0] quality_requested,
    input [7:0] spatial_threshold_requested,
    input spatial_adaptive_requested,
    output reg [1:0] active_quality
);
    (* ASYNC_REG="TRUE" *) reg [2:0] reset_pipe=0;
    always @(posedge sys_clk or negedge sys_rst_n)
        if (!sys_rst_n) reset_pipe<=0;
        else reset_pipe<={reset_pipe[1:0],1'b1};
    wire rst_n=reset_pipe[2];

    localparam IDLE=0,DIM=1,MODE=2,QREAD=3,QVALUE=4,QRECIP=5,
               TABLES=6,PREAD=7,PSEND=8,WAIT_DESC=9,FINISH=10;
    reg [3:0] state;
    reg [1:0] test_case, round_no;
    reg [6:0] q_index;
    reg [21:0] pixel_index;
    reg [15:0] x,y;
    reg [1:0] resolution,pending_resolution;
    reg done, error_seen,continuous,stop_requested,command_pending,pending_continuous;
    reg [1:0] loading_quality;
    wire quality_pending=BOARD_CONTROL && quality_requested!=active_quality;
    wire stop_now=BOARD_CONTROL?!run_requested:(rx_valid && rx_data=="S");
    wire start;
    wire [15:0] width=REAL_CAMERA?CAMERA_WIDTH:(resolution==1)?VGA_WIDTH:(resolution==2)?HD_WIDTH:(resolution==3)?FHD_WIDTH:
                             (test_case==1)?16'd32:16'd16;
    wire [15:0] height=REAL_CAMERA?CAMERA_HEIGHT:(resolution==1)?VGA_HEIGHT:(resolution==2)?HD_HEIGHT:(resolution==3)?FHD_HEIGHT:
                              (test_case==0)?16'd16:((test_case==1)?16'd24:16'd8);
    wire [21:0] pixel_count=(resolution==1)?VGA_WIDTH*VGA_HEIGHT:(resolution==2)?HD_WIDTH*HD_HEIGHT:(resolution==3)?FHD_WIDTH*FHD_HEIGHT:
                                  (test_case==0)?22'd256:((test_case==1)?22'd768:22'd128);
    wire [10:0] pixel_base=(test_case==0) ? 11'd0 : ((test_case==1) ? 11'd256 : 11'd1024);
    (* rom_style="block" *) reg [15:0] pixels[0:1151];
    (* rom_style="block" *) reg [28:0] quant[0:383];
    (* rom_style="block" *) reg [28:0] camera_quant[0:383];
    reg [15:0] pixel;
    wire [15:0] gradient_pixel;
    board_test_gradient gradient(.x(x),.y(y),.pixel(gradient_pixel));
    // Raster coordinates advance only on valid/ready. The combinational
    // gradient therefore supplies the next pixel each clock and holds under
    // backpressure. The small ROM keeps its synchronous read cycle.
    wire [15:0] source_pixel=REAL_CAMERA?camera_pixel:(resolution!=0)?gradient_pixel:pixel;
    reg [28:0] q;
    initial begin
        $readmemh("data/board_test/pixels.mem",pixels);
        $readmemh("data/board_test/quant.mem",quant);
        $readmemh("data/board_test/camera_quant.mem",camera_quant);
    end
    always @(posedge sys_clk) begin
        if (state==PREAD) pixel<=pixels[pixel_base+pixel_index[10:0]];
        if (state==QREAD) q<=BOARD_CONTROL?camera_quant[{loading_quality,q_index}]:
                            quant[(resolution!=0)?{2'd0,q_index}:{test_case,q_index}];
    end
    reg [2:0] cfg_cmd;
    reg [31:0] cfg_data;
    reg cfg_valid;
    wire cfg_ready, s_ready, busy, tables_ready, config_error;
    always @* begin
        cfg_valid=1; cfg_cmd=0; cfg_data=0;
        case (state)
            DIM: begin cfg_cmd=0; cfg_data={height,width}; end
            MODE: begin cfg_cmd=1; cfg_data=(!REAL_CAMERA && resolution==0 && test_case==0)?32'd3:32'd1; end
            QVALUE: begin cfg_cmd=2; cfg_data={17'd0,q[7:0],q_index}; end
            QRECIP: begin cfg_cmd=3; cfg_data={11'd0,q[28:8]}; end
            default: cfg_valid=0;
        endcase
    end
    wire [31:0] m_data;
    wire [2:0] m_bytes;
    wire m_valid, m_ready, m_packet_last;
    wire source_valid=state==PSEND && (!REAL_CAMERA || camera_valid);
    wire source_sof=REAL_CAMERA?camera_sof:pixel_index==0;
    wire source_eol=REAL_CAMERA?camera_eol:x==width-1;
    wire source_eof=REAL_CAMERA?camera_eof:pixel_index==pixel_count-1;
    assign camera_take=REAL_CAMERA && state==PSEND && s_ready;
    assign camera_admit=REAL_CAMERA && state==PSEND && tables_ready && camera_ready && !busy &&
                        !stop_requested && !stop_now && !quality_pending;
    mjpeg_synth_top #(.CHANNELS(1),.MAX_WIDTH(REAL_CAMERA?CAMERA_WIDTH:1920),.COALESCE(1),
        .RESTART_MCUS(SPATIAL_SKIP?4:0),.SPATIAL_SKIP(SPATIAL_SKIP),.SPATIAL_THRESHOLD(SPATIAL_THRESHOLD),.SPATIAL_DDR(SPATIAL_DDR),.SPATIAL_ADAPTIVE(SPATIAL_ADAPTIVE)) codec(
        .mem_cmd_valid(mem_cmd_valid),.mem_cmd_write(mem_cmd_write),.mem_cmd_ready(mem_cmd_ready),.mem_cmd_addr(mem_cmd_addr),
        .mem_cmd_bytes(mem_cmd_bytes),.mem_w_data(mem_w_data),.mem_w_keep(mem_w_keep),.mem_w_valid(mem_w_valid),
        .mem_w_last(mem_w_last),.mem_w_ready(mem_w_ready),.mem_r_data(mem_r_data),.mem_r_valid(mem_r_valid),
        .mem_r_last(mem_r_last),.mem_r_ready(mem_r_ready),.mem_done(mem_done),.mem_error(mem_error),
        .mem_fault(mem_fault),
        .clk(sys_clk),.rst_n(rst_n),.cfg_cmd(cfg_cmd),.cfg_channel(2'd0),
        .cfg_data(cfg_data),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),
        .cfg_skip_threshold(spatial_threshold_requested),
        .cfg_skip_adaptive(spatial_adaptive_requested),
        .cfg_skip_pressure(REAL_CAMERA && camera_queue_pressure),
        .s_data(source_pixel),.s_valid(source_valid),.s_ready(s_ready),
        .s_sof(source_sof),.s_eol(source_eol),.s_eof(source_eof),.s_abort(REAL_CAMERA && camera_abort),
        .m_data(m_data),.m_bytes(m_bytes),.m_valid(m_valid),.m_ready(m_ready),
        .m_packet_last(m_packet_last),.busy(busy),.tables_ready(tables_ready),.config_error(config_error));

    // The byte transport stalls this boundary; JPEG bytes are never substituted.
    reg [39:0] record;
    reg [2:0] remaining, preamble;
    reg [2:0] packet_index;
    reg descriptor;
    reg telemetry_pending,telemetry_active;
    reg timing_pending,timing_active;
    reg camera_pending,camera_active;
    reg [3:0] camera_index;
    reg [255:0] camera_pending_data,camera_active_data;
    reg [95:0] preprocess_pending_data,preprocess_active_data;
    reg end_pending;
    assign m_ready=(state!=IDLE) && preamble==0 && remaining==0 &&
                   !telemetry_active && !telemetry_pending && !timing_active && !timing_pending &&
                   !camera_active && !camera_pending;
    wire word_taken=m_valid && m_ready;
    wire descriptor_done=word_taken && m_packet_last && descriptor;
    wire input_frame=source_valid && s_ready && source_sof;
    wire success_frame=descriptor_done && m_data[7:0]==0;
    wire failed_frame=descriptor_done && m_data[7:0]!=0;
    wire [31:0] fps_window_id,input_fps,failed_fps,total_compressed;
    frame_rate_meter #(.CLOCK_HZ(CLOCK_HZ)) meter(
        .clk(sys_clk),.rst_n(rst_n),.input_frame(input_frame),.success_frame(success_frame),.failed_frame(failed_frame),
        .sample_valid(fps_sample_valid),.window_id(fps_window_id),.input_fps(input_fps),
        .compressed_fps(compressed_fps),.failed_fps(failed_fps),.total_compressed(total_compressed));
    assign start=(state==IDLE) && (BOARD_CONTROL?run_requested:command_pending) && remaining==0 && preamble==0 &&
                 !telemetry_active && !telemetry_pending && !timing_active && !timing_pending &&
                 !camera_active && !camera_pending && !end_pending && tx_ready;
    reg [2:0] telemetry_index;
    reg [31:0] pending_window,pending_input,pending_fps,pending_failed,pending_total;
    reg [31:0] active_window,active_input,active_fps,active_failed,active_total;
    reg [31:0] telemetry_data;
    always @* begin
        case(telemetry_index)
            0:telemetry_data=32'h31535046; // little-endian ASCII FPS1
            1:telemetry_data=active_window;2:telemetry_data=active_input;
            3:telemetry_data=active_fps;4:telemetry_data=active_failed;5:telemetry_data=active_total;
            default:telemetry_data=0;
        endcase
    end
    always @(posedge sys_clk or negedge rst_n) begin
        if(!rst_n) begin
            telemetry_pending<=0;telemetry_active<=0;telemetry_index<=0;
            pending_window<=0;pending_input<=0;pending_fps<=0;pending_failed<=0;pending_total<=0;
            active_window<=0;active_input<=0;active_fps<=0;active_failed<=0;active_total<=0;
        end else begin
            if(!telemetry_active && !timing_active && !camera_active && telemetry_pending && remaining==0 && preamble==0 && !start) begin
                telemetry_active<=1;telemetry_pending<=0;telemetry_index<=0;
                active_window<=pending_window;active_input<=pending_input;active_fps<=pending_fps;
                active_failed<=pending_failed;active_total<=pending_total;
            end
            if(telemetry_active && remaining==0) begin
                if(telemetry_index==5) begin telemetry_active<=0;telemetry_index<=0; end
                else telemetry_index<=telemetry_index+1'b1;
            end
            // If USB blocks longer than one second, retain the newest unsent
            // snapshot; an active six-record snapshot is never overwritten.
            if(fps_sample_valid) begin
                telemetry_pending<=1;pending_window<=fps_window_id;pending_input<=input_fps;
                pending_fps<=compressed_fps;pending_failed<=failed_fps;pending_total<=total_compressed;
            end
        end
    end
    // Frame timings include transport backpressure. They do not measure an
    // isolated encoder running into an always-ready output sink.
    reg [31:0] timebase,frame_start_tick,feed_ticks,jpeg_ticks,input_wait,output_wait,timing_frame_id;
    reg frame_measured,last_payload;
    reg [2:0] timing_index;
    reg [31:0] report_id,report_feed,report_jpeg,report_total,report_input_wait,report_output_wait;
    reg [31:0] timing_data;
    always @* begin
        case(timing_index)
            0:timing_data=32'h314d4954; // TIM1
            1:timing_data=report_id;2:timing_data=report_feed;3:timing_data=report_jpeg;
            4:timing_data=report_total;5:timing_data=report_input_wait;6:timing_data=report_output_wait;
            default:timing_data=0;
        endcase
    end
    always @(posedge sys_clk or negedge rst_n) begin
        if(!rst_n) begin
            timebase<=0;frame_start_tick<=0;feed_ticks<=0;jpeg_ticks<=0;input_wait<=0;output_wait<=0;
            timing_frame_id<=0;frame_measured<=0;last_payload<=0;timing_pending<=0;timing_active<=0;timing_index<=0;
            report_id<=0;report_feed<=0;report_jpeg<=0;report_total<=0;report_input_wait<=0;report_output_wait<=0;
        end else begin
            timebase<=timebase+1'b1;
            if(input_frame) begin
                frame_start_tick<=timebase;feed_ticks<=0;jpeg_ticks<=0;input_wait<=0;output_wait<=0;
                frame_measured<=REAL_CAMERA || resolution!=0;
            end
            if(frame_measured) begin
                if(source_valid && !s_ready) input_wait<=input_wait+1'b1;
                if(m_valid && !m_ready) output_wait<=output_wait+1'b1;
                if(source_valid && s_ready && source_eof) feed_ticks<=timebase-frame_start_tick;
                if(word_taken && m_packet_last && !descriptor && last_payload) jpeg_ticks<=timebase-frame_start_tick;
            end
            if(word_taken && packet_index==0) last_payload<=m_data[11:10]==0 && m_data[6];
            if(word_taken && packet_index==1 && descriptor) timing_frame_id<=m_data;
            if(descriptor_done && frame_measured) begin
                frame_measured<=0;timing_pending<=m_data[7:0]==0;
                report_id<=timing_frame_id;report_feed<=feed_ticks;report_jpeg<=jpeg_ticks;
                report_total<=timebase-frame_start_tick;report_input_wait<=input_wait;report_output_wait<=output_wait;
            end
            if(!timing_active && timing_pending && remaining==0 && preamble==0 &&
               !telemetry_active && !telemetry_pending && !camera_active && !start) begin
                timing_active<=1;timing_pending<=0;timing_index<=0;
            end
            if(timing_active && remaining==0) begin
                if(timing_index==6) begin timing_active<=0;timing_index<=0; end
                else timing_index<=timing_index+1'b1;
            end
        end
    end
    // Status also flows while idle or initialization fails; no camera pixels
    // are required to read chip ID, clocks, overflow and admission counters.
    always @(posedge sys_clk or negedge rst_n) begin
        if(!rst_n) begin
            camera_pending<=0;camera_active<=0;camera_index<=0;
            camera_pending_data<=0;camera_active_data<=0;
            preprocess_pending_data<=0;preprocess_active_data<=0;
        end else begin
            if(REAL_CAMERA && fps_sample_valid) begin
                camera_pending<=1;
                camera_pending_data<={camera_status[255:32],camera_status[31:7],state!=IDLE,camera_status[5:0]};
                if(PREPROCESS_ENABLE) preprocess_pending_data<=preprocess_status;
            end
            if(!camera_active && camera_pending && remaining==0 && preamble==0 &&
               !telemetry_active && !telemetry_pending && !timing_active && !timing_pending && !start) begin
                camera_active<=1;camera_pending<=0;camera_index<=0;camera_active_data<=camera_pending_data;
                if(PREPROCESS_ENABLE) preprocess_active_data<=preprocess_pending_data;
            end
            if(camera_active && remaining==0) begin
                if(camera_index==(PREPROCESS_ENABLE?12:8)) begin camera_active<=0;camera_index<=0;end
                else camera_index<=camera_index+1'b1;
            end
        end
    end
    always @* begin
        tx_valid=0; tx_data=0;
        if (preamble!=0) begin
            tx_valid=1;
            case (preamble)
                4: tx_data="M"; 3: tx_data="J"; 2: tx_data="B"; 1: tx_data="T";
                default: tx_data=0;
            endcase
        end else if (remaining!=0) begin tx_valid=1; tx_data=record[7:0]; end
    end
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin record<=0; remaining<=0; preamble<=0; packet_index<=0; descriptor<=0;end_pending<=0; end
        else begin
            if (start) begin preamble<=4; packet_index<=0; descriptor<=0; end
            if (tx_valid && tx_ready) begin
                if (preamble!=0) preamble<=preamble-1'b1;
                else begin remaining<=remaining-1'b1; record<={8'd0,record[39:8]}; end
            end
            if (word_taken) begin
                record<={4'd0,m_packet_last,m_bytes,m_data}; remaining<=5;
                if (packet_index==0) descriptor<=m_data[11:10]==1;
                packet_index<=m_packet_last ? 0 : packet_index+1'b1;
            end
            if(telemetry_active && remaining==0) begin
                record<={(8'h80+{5'd0,telemetry_index}),telemetry_data};remaining<=5;
            end
            if(timing_active && remaining==0) begin
                record<={(8'h90+{5'd0,timing_index}),timing_data};remaining<=5;
            end
            if(camera_active && remaining==0) begin
                record<={(8'hb0+{4'd0,camera_index}),camera_index==0?32'h314d4143:
                    camera_index==9?32'h31505250:camera_index>9?preprocess_active_data[(camera_index-10)*32+:32]:
                    camera_active_data[(camera_index-1)*32+:32]};remaining<=5;
            end
            if(state==FINISH && remaining==0 && tx_ready && !m_valid && !busy &&
               !telemetry_active && !telemetry_pending && !timing_active && !timing_pending && !camera_active && !camera_pending)
                end_pending<=(resolution!=0)||SMALL_END;
            if(end_pending && remaining==0 && !telemetry_active && !telemetry_pending && !timing_active && !timing_pending && !camera_active && !camera_pending) begin
                record<={8'ha0,32'h31444e45};remaining<=5;end_pending<=0; // END1
            end
        end
    end
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; test_case<=0; round_no<=0; q_index<=0; pixel_index<=0; x<=0;y<=0; done<=0; error_seen<=0;
            resolution<=0;pending_resolution<=0;
            continuous<=0;stop_requested<=0;command_pending<=0;pending_continuous<=0;
            active_quality<=2;loading_quality<=2;
        end else begin
            if(rx_valid && state==IDLE && (rx_data=="G" || rx_data=="C" || rx_data=="V" || rx_data=="H" || rx_data=="F")) begin
                command_pending<=1;pending_continuous<=rx_data!="G";
                pending_resolution<=(rx_data=="V")?1:(rx_data=="H")?2:(rx_data=="F")?3:0;
            end
            if(stop_now && state!=IDLE) stop_requested<=1;
            if (config_error && (state==PSEND || state==WAIT_DESC)) error_seen<=1;
            if (descriptor_done && m_data[7:0]!=0) error_seen<=1;
            case (state)
                IDLE: if (start) begin
                    state<=DIM;test_case<=0;round_no<=0;done<=0;error_seen<=0;
                    continuous<=BOARD_CONTROL?1'b1:pending_continuous;
                    resolution<=BOARD_CONTROL?2'd0:pending_resolution;stop_requested<=0;command_pending<=0;
                    loading_quality<=BOARD_CONTROL?quality_requested:2'd2;
                end
                DIM: if (cfg_ready) state<=MODE;
                MODE: if (cfg_ready) begin state<=QREAD; q_index<=0; end
                QREAD: state<=QVALUE;
                QVALUE: if (cfg_ready) state<=QRECIP;
                QRECIP: if (cfg_ready) begin
                    if (q_index==127) state<=TABLES;
                    else begin q_index<=q_index+1'b1; state<=QREAD; end
                end
                TABLES: if(REAL_CAMERA && (stop_requested || stop_now)) state<=FINISH;
                else if (tables_ready && !config_error && (!REAL_CAMERA || camera_ready)) begin
                    active_quality<=loading_quality;
                    if(BOARD_CONTROL && quality_requested!=loading_quality) begin
                        loading_quality<=quality_requested;q_index<=0;state<=QREAD;
                    end else begin
                        pixel_index<=0;x<=0;y<=0;state<=(REAL_CAMERA || resolution!=0)?PSEND:PREAD;
                    end
                end
                PREAD: state<=PSEND;
                PSEND: if(REAL_CAMERA && camera_abort && busy) state<=WAIT_DESC;
                else if(REAL_CAMERA && !busy && !camera_valid && !camera_status[2] && !camera_admission_enabled &&
                        (stop_requested || stop_now || quality_pending)) begin
                    if(stop_requested || stop_now) state<=FINISH;
                    else begin loading_quality<=quality_requested;q_index<=0;state<=QREAD;end
                end
                else if (source_valid && s_ready) begin
                    if (source_eof) state<=WAIT_DESC;
                    else begin
                        pixel_index<=pixel_index+1'b1;
                        if(x==width-1) begin x<=0;y<=y+1'b1; end else x<=x+1'b1;
                        state<=(REAL_CAMERA || resolution!=0)?PSEND:PREAD;
                    end
                end
                WAIT_DESC: if (descriptor_done) begin
                    if(stop_requested || stop_now) state<=FINISH;
                    else if(REAL_CAMERA) begin pixel_index<=0;x<=0;y<=0;state<=PSEND;end
                    else if(resolution!=0) state<=DIM;
                    else if (test_case==2) begin
                        if(continuous) begin test_case<=0;state<=DIM; end
                        else
                        if (round_no==2) state<=FINISH;
                        else begin round_no<=round_no+1'b1; test_case<=0; state<=DIM; end
                    end else begin test_case<=test_case+1'b1; state<=DIM; end
                end
                FINISH: if (remaining==0 && tx_ready && !m_valid && !busy && !telemetry_active && !telemetry_pending &&
                           !timing_active && !timing_pending && !camera_active && !camera_pending) begin state<=IDLE; done<=1; end
                default: state<=IDLE;
            endcase
        end
    end
    assign led={error_seen,done,(state!=IDLE),tables_ready};
endmodule

// Physical board top. The default uses synchronous FT245 + dual-clock queues.
// SYNC_FIFO=0 preserves the previous asynchronous transport for regression.
module davinci_mjpeg_board_test_top #(
    parameter CLOCK_HZ=100000000,USB_CLOCK_HZ=60000000,SYNC_FIFO=1,USE_MMCM=1,
    REAL_CAMERA=0,CAMERA_PROFILE=1,SPATIAL_SKIP=0,SPATIAL_THRESHOLD=0,
    CAMERA_WIDTH=(CAMERA_PROFILE>=4)?1920:(CAMERA_PROFILE>=2)?1280:640,
    CAMERA_HEIGHT=(CAMERA_PROFILE>=4)?1080:(CAMERA_PROFILE>=2)?720:480,
    VGA_WIDTH=640,VGA_HEIGHT=480,HD_WIDTH=1280,HD_HEIGHT=720,FHD_WIDTH=1920,FHD_HEIGHT=1080
)(
    input sys_clk, sys_rst_n,usb_clk_60m,input [3:0] key,
    inout [7:0] usb_data,
    input usb_rxf_n, usb_txe_n,
    output usb_rd_n, usb_wr_n, usb_oe_n, usb_siwu_n,
    output [3:0] led,output [5:0] seg_sel,output [7:0] seg_led,
    input cam_pclk,cam_vsync,cam_href,input [7:0] cam_data,
    output cam_rst_n,cam_pwdn,cam_scl,inout cam_sda
);
    wire core_clk,core_clock_locked;
    generate if(USE_MMCM) begin: multiplied_clock
        board_test_core_clock clock_generator(.ref_clk(sys_clk),.rst_n(sys_rst_n),
            .core_clk(core_clk),.locked(core_clock_locked));
    end else begin: bypass_clock
        // Only for legacy simulation with an externally supplied core clock.
        assign core_clk=sys_clk;
        assign core_clock_locked=sys_rst_n;
    end endgenerate
    wire [7:0] rx_data,tx_data;
    wire rx_valid,tx_valid,tx_ready;
    wire [7:0] engine_tx_data;
    wire engine_tx_valid,engine_tx_ready,link_stats_valid;
    wire [223:0] link_stats_data;
    wire rst_n,run_rst_n;
    (* ASYNC_REG="TRUE" *) reg [2:0] reset_pipe=0;
    always @(posedge core_clk or negedge run_rst_n)
        if (!run_rst_n) reset_pipe<=0;
        else reset_pipe<={reset_pipe[1:0],1'b1};
    assign rst_n=reset_pipe[2];
    generate if(SYNC_FIFO) begin: synchronous
        wire usb_clk,usb_rst_n;
        BUFG usb_clock_buffer(.I(usb_clk_60m),.O(usb_clk));
        board_test_usb_clock_guard #(.TIMEOUT_CYCLES(USE_MMCM?100000:50000)) clock_guard(
            .sys_clk(core_clk),.usb_clk(usb_clk),.sys_rst_n(core_clock_locked),.run_rst_n(run_rst_n));
        (* ASYNC_REG="TRUE" *) reg [2:0] usb_reset_pipe=0;
        always @(posedge usb_clk or negedge run_rst_n)
            if(!run_rst_n) usb_reset_pipe<=0;
            else usb_reset_pipe<={usb_reset_pipe[1:0],1'b1};
        assign usb_rst_n=usb_reset_pipe[2];
        wire [7:0] usb_tx_data,usb_rx_data;
        wire usb_tx_valid,usb_tx_ready,usb_rx_valid,usb_rx_ready;
        wire usb_stats_valid;
        wire [223:0] usb_stats_data;
        // 8 KiB TX and 256-byte command FIFO. BRAM ports have local clocks.
        board_test_async_fifo #(.ADDRESS_BITS(13)) tx_fifo(
            .wclk(core_clk),.wrst_n(rst_n),.s_data(tx_data),.s_valid(tx_valid),.s_ready(tx_ready),
            .rclk(usb_clk),.rrst_n(usb_rst_n),.m_data(usb_tx_data),.m_valid(usb_tx_valid),.m_ready(usb_tx_ready));
        board_test_async_fifo #(.ADDRESS_BITS(8),.RAM_STYLE("distributed")) rx_fifo(
            .wclk(usb_clk),.wrst_n(usb_rst_n),.s_data(usb_rx_data),.s_valid(usb_rx_valid),.s_ready(usb_rx_ready),
            .rclk(core_clk),.rrst_n(rst_n),.m_data(rx_data),.m_valid(rx_valid),.m_ready(1'b1));
        board_test_ft245_sync #(.CLOCK_HZ(USB_CLOCK_HZ)) link(
            .clk(usb_clk),.rst_n(usb_rst_n),.usb_data(usb_data),.usb_rxf_n(usb_rxf_n),.usb_txe_n(usb_txe_n),
            .usb_rd_n(usb_rd_n),.usb_wr_n(usb_wr_n),.usb_oe_n(usb_oe_n),.usb_siwu_n(usb_siwu_n),
            .rx_data(usb_rx_data),.rx_valid(usb_rx_valid),.rx_ready(usb_rx_ready),
            .tx_data(usb_tx_data),.tx_valid(usb_tx_valid),.tx_ready(usb_tx_ready),
            .stats_valid(usb_stats_valid),.stats_data(usb_stats_data));
        board_test_cdc_snapshot stats_mailbox(
            .s_clk(usb_clk),.s_rst_n(usb_rst_n),.s_valid(usb_stats_valid),.s_data(usb_stats_data),
            .m_clk(core_clk),.m_rst_n(rst_n),.m_valid(link_stats_valid),.m_data(link_stats_data));
    end else begin: asynchronous
    assign run_rst_n=core_clock_locked;
    board_test_ft245_async #(.CLOCK_HZ(CLOCK_HZ)) link(
        .clk(core_clk),.rst_n(rst_n),.usb_data(usb_data),.usb_rxf_n(usb_rxf_n),.usb_txe_n(usb_txe_n),
        .usb_rd_n(usb_rd_n),.usb_wr_n(usb_wr_n),.usb_oe_n(usb_oe_n),.usb_siwu_n(usb_siwu_n),
        .rx_data(rx_data),.rx_valid(rx_valid),.tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),
        .stats_valid(link_stats_valid),.stats_data(link_stats_data));
    end endgenerate
    board_test_block_transport blocks(
        .clk(core_clk),.rst_n(rst_n),.s_data(engine_tx_data),.s_valid(engine_tx_valid),.s_ready(engine_tx_ready),
        .m_data(tx_data),.m_valid(tx_valid),.m_ready(tx_ready),
        .stats_valid(link_stats_valid),.stats_data(link_stats_data));
    wire [31:0] compressed_fps;
    wire fps_sample_valid;
    wire [15:0] camera_pixel;
    wire camera_valid,camera_sof,camera_eol,camera_eof,camera_abort,camera_ready,camera_take,camera_admit;
    wire [255:0] camera_status;
    wire camera_admission_enabled;
    wire [3:0] engine_led;
    wire run_requested,board_light_start,board_light_cancel;
    wire [1:0] quality_requested,active_quality;
    wire [7:0] spatial_threshold_requested;
    generate if(REAL_CAMERA) begin: real_camera
        wire init_done,init_error,capture_active;
        wire light_requested,light_on,light_error,light_busy;
        camera_board_controls #(.CLOCK_HZ(CLOCK_HZ)) controls(
            .clk(core_clk),.reset_n(core_clock_locked),.key_n(key),.rx_data(rx_data),.rx_valid(rx_valid),
            .streaming(engine_led[1]),.camera_ready(camera_ready),.active_quality(active_quality),
            .light_on(light_on),.fault(init_error || light_error || engine_led[3]),
            .run_requested(run_requested),.quality_requested(quality_requested),
            .spatial_threshold_requested(spatial_threshold_requested),
            .light_start(board_light_start),.light_cancel(board_light_cancel),.led(led));
        wire [15:0] chip_id,ack_error_count,last_reg_addr;
        wire [8:0] reg_index;
        wire [31:0] received_frames,dropped_frames,overflow_count,frame_sync_count,dvp_byte_count,captured_pixels,pclk_ticks;
        wire pclk;
        wire sample_locked;
        wire capture_reset_n;
        wire capture_reset_request_n=rst_n && sample_locked;
        (* ASYNC_REG="TRUE" *) reg [2:0] capture_reset_pipe;
        (* ASYNC_REG="TRUE" *) reg [1:0] sampling_lock_sync;
        reg sampling_lock_previous,clock_loss_abort;
        always @(posedge core_clk or negedge capture_reset_request_n) begin
            if(!capture_reset_request_n) capture_reset_pipe<=0;
            else capture_reset_pipe<={capture_reset_pipe[1:0],1'b1};
        end
        always @(posedge core_clk or negedge rst_n) begin
            if(!rst_n) begin sampling_lock_sync<=0;sampling_lock_previous<=0;clock_loss_abort<=0;end
            else begin
                sampling_lock_sync<={sampling_lock_sync[0],sample_locked};
                sampling_lock_previous<=sampling_lock_sync[1];
                clock_loss_abort<=sampling_lock_previous && !sampling_lock_sync[1];
            end
        end
        assign capture_reset_n=capture_reset_pipe[2];
        wire sda_i,sda_drive_low;
        reg admit;
        always @(posedge core_clk or negedge rst_n)
            if(!rst_n) admit<=0;else admit<=camera_admit;
        if(CAMERA_PROFILE>=3) begin: phase_clock
            ov5640_sample_clock sampling_clock(.pclk(cam_pclk),
                .reset(!rst_n || !init_done),.sample_clock(pclk),.locked(sample_locked));
        end else begin: direct_clock
            BUFG camera_clock_buffer(.I(cam_pclk),.O(pclk));
            assign sample_locked=1'b1;
        end
        // A single aligned input register stage keeps high-rate DVP pin
        // timing separate from byte assembly, fault detection and FIFO logic.
        (* IOB="TRUE" *) reg [7:0] pin_data;
        (* IOB="TRUE" *) reg pin_vsync,pin_href;
        if(CAMERA_PROFILE>=2) begin: late_sampling
            always @(negedge pclk) begin
                pin_data<=cam_data;pin_vsync<=cam_vsync;pin_href<=cam_href;
            end
        end else begin: rising_sampling
            always @(posedge pclk) begin
                pin_data<=cam_data;pin_vsync<=cam_vsync;pin_href<=cam_href;
            end
        end
        IOBUF camera_sda_buffer(.I(1'b0),.T(!sda_drive_low),.O(sda_i),.IO(cam_sda));
        ov5640_init #(.CLK_HZ(CLOCK_HZ),.CAMERA_PROFILE(CAMERA_PROFILE)) initialization(
            .clk(core_clk),.rst_n(rst_n),.cam_rst_n(cam_rst_n),.cam_pwdn(cam_pwdn),
            .light_start(board_light_start),.light_cancel(board_light_cancel),
            .light_requested(light_requested),.light_on(light_on),.light_error(light_error),.light_busy(light_busy),
            .cam_scl(cam_scl),.cam_sda_i(sda_i),.cam_sda_drive_low(sda_drive_low),.init_done(init_done),.init_error(init_error),
            .chip_id(chip_id),.reg_index(reg_index),.ack_error_count(ack_error_count),.last_reg_addr(last_reg_addr));
        wire [15:0] raw_pixel;
        wire raw_valid,raw_ready,raw_sof,raw_eol,raw_eof,dvp_abort;
        assign camera_abort=dvp_abort || clock_loss_abort;
        ov5640_dvp_capture #(.WIDTH(CAMERA_WIDTH),.HEIGHT(CAMERA_HEIGHT),.YUV_BYTE_ORDER(0),.RAW8(CAMERA_PROFILE==5),.SAMPLE_FALLING(CAMERA_PROFILE>=2)) capture(
            .pclk(pclk),.rst_n(capture_reset_n),.enable(admit),.cam_vsync(pin_vsync),.cam_href(pin_href),.cam_data(pin_data),
            .core_clk(core_clk),.core_rst_n(capture_reset_n),.s_data(raw_pixel),.s_valid(raw_valid),.s_ready(raw_ready),
            .s_sof(raw_sof),.s_eol(raw_eol),.s_eof(raw_eof),.s_abort(dvp_abort),
            .capture_active(capture_active),.admission_enabled(camera_admission_enabled),.received_frames(received_frames),.dropped_frames(dropped_frames),
            .overflow_count(overflow_count),.frame_sync_count(frame_sync_count),.dvp_byte_count(dvp_byte_count),
            .captured_pixels(captured_pixels),.pclk_ticks(pclk_ticks));
        if(CAMERA_PROFILE==5) begin: raw_processing
            // Profile-5 3820=42 aligns optical RAW and ISP channels as BGGR.
            bayer_bggr_to_yuv422 #(.WIDTH(CAMERA_WIDTH),.HEIGHT(CAMERA_HEIGHT),.BAYER_PATTERN(0)) demosaic(
                .clk(core_clk),.rst_n(capture_reset_n),.abort(camera_abort),
                .s_data(raw_pixel[7:0]),.s_valid(raw_valid),.s_ready(raw_ready),
                .s_sof(raw_sof),.s_eol(raw_eol),.s_eof(raw_eof),
                .m_data(camera_pixel),.m_valid(camera_valid),.m_ready(camera_take),
                .m_sof(camera_sof),.m_eol(camera_eol),.m_eof(camera_eof));
        end else begin: yuv_processing
            assign camera_pixel=raw_pixel;assign camera_valid=raw_valid;assign raw_ready=camera_take;
            assign camera_sof=raw_sof;assign camera_eol=raw_eol;assign camera_eof=raw_eof;
        end
        assign camera_ready=init_done && capture_reset_n;
        assign camera_status={dvp_byte_count,overflow_count,dropped_frames,received_frames,pclk_ticks,
            frame_sync_count[31:16],7'd0,reg_index,frame_sync_count[15:0],chip_id,
            (SPATIAL_THRESHOLD!=0),spatial_threshold_requested,(quality_requested!=active_quality),quality_requested,active_quality,run_requested,1'b1,
            1'b1,capture_reset_n,(CAMERA_PROFILE==5),1'b1,light_busy,light_error,light_on,light_requested,
            2'd0,engine.config_error,engine.busy,engine.tables_ready,capture_active,init_error,init_done};
    end else begin: simulated_camera
        assign camera_pixel=0;assign camera_valid=0;assign camera_sof=0;assign camera_eol=0;assign camera_eof=0;
        assign camera_abort=0;assign camera_ready=1;assign camera_status=0;
        assign camera_admission_enabled=0;
        assign cam_rst_n=0;assign cam_pwdn=1;assign cam_scl=1'bz;assign cam_sda=1'bz;
        assign led=engine_led;
        assign run_requested=0;assign quality_requested=2;
        assign spatial_threshold_requested=0;
        assign board_light_start=0;assign board_light_cancel=0;
    end endgenerate
    mjpeg_board_test_engine #(.CLOCK_HZ(CLOCK_HZ),.SMALL_END(1),.REAL_CAMERA(REAL_CAMERA),.BOARD_CONTROL(REAL_CAMERA),.SPATIAL_SKIP(SPATIAL_SKIP),.SPATIAL_THRESHOLD(SPATIAL_THRESHOLD),
        .CAMERA_WIDTH(CAMERA_WIDTH),.CAMERA_HEIGHT(CAMERA_HEIGHT),
        .VGA_WIDTH(VGA_WIDTH),.VGA_HEIGHT(VGA_HEIGHT),.HD_WIDTH(HD_WIDTH),.HD_HEIGHT(HD_HEIGHT),
        .FHD_WIDTH(FHD_WIDTH),.FHD_HEIGHT(FHD_HEIGHT)) engine(
        .sys_clk(core_clk),.sys_rst_n(run_rst_n),.rx_data(rx_data),.rx_valid(rx_valid),
        .tx_data(engine_tx_data),.tx_valid(engine_tx_valid),.tx_ready(engine_tx_ready),.led(engine_led),
        .camera_pixel(camera_pixel),.camera_valid(camera_valid),.camera_sof(camera_sof),.camera_eol(camera_eol),
        .camera_eof(camera_eof),.camera_abort(camera_abort),.camera_ready(camera_ready),.camera_queue_pressure(1'b0),.camera_status(camera_status),
        .camera_admission_enabled(camera_admission_enabled),
        .camera_take(camera_take),.camera_admit(camera_admit),
        .run_requested(run_requested),.quality_requested(quality_requested),.active_quality(active_quality),
        .spatial_threshold_requested(spatial_threshold_requested),
        .compressed_fps(compressed_fps),.fps_sample_valid(fps_sample_valid));
    davinci_fps_display #(.CLOCK_HZ(CLOCK_HZ)) display(
        .clk(core_clk),.rst_n(rst_n),.fps(compressed_fps),.update_valid(fps_sample_valid),
        .seg_sel(seg_sel),.seg_led(seg_led),.bcd_value());
endmodule

// Kept for the independently verified UART waveform test, not this board build.
module davinci_mjpeg_uart_test_top #(parameter UART_DIVISOR=434)(
    input sys_clk,sys_rst_n,usb_uart_rx, output usb_uart_tx, output [3:0] led
);
    reg [2:0] reset_pipe=0;
    always @(posedge sys_clk or negedge sys_rst_n)
        if (!sys_rst_n) reset_pipe<=0;
        else reset_pipe<={reset_pipe[1:0],1'b1};
    wire [7:0] rx_data,tx_data;
    wire rx_valid,tx_valid,tx_ready;
    board_test_uart_rx #(.DIVISOR(UART_DIVISOR)) rx(
        .clk(sys_clk),.rst_n(reset_pipe[2]),.rx(usb_uart_rx),.data(rx_data),.valid(rx_valid));
    board_test_uart_tx #(.DIVISOR(UART_DIVISOR)) tx(
        .clk(sys_clk),.rst_n(reset_pipe[2]),.data(tx_data),.valid(tx_valid),.ready(tx_ready),.tx(usb_uart_tx));
    mjpeg_board_test_engine engine(
        .sys_clk(sys_clk),.sys_rst_n(sys_rst_n),.rx_data(rx_data),.rx_valid(rx_valid),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.led(led));
endmodule
