module davinci_mjpeg_ddr3_top #(
    parameter CLOCK_HZ=100000000,USB_CLOCK_HZ=60000000,SYNC_FIFO=1,USE_MMCM=1,
    REAL_CAMERA=0,CAMERA_PROFILE=1,SPATIAL_SKIP=0,SPATIAL_THRESHOLD=0,SPATIAL_ADAPTIVE=0,DENOISE_ENABLE=1,PREPROCESS_ENABLE=1,
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
    output cam_rst_n,cam_pwdn,cam_scl,inout cam_sda,
    inout [15:0] ddr3_dq,inout [1:0] ddr3_dqs_n,ddr3_dqs_p,
    output [13:0] ddr3_addr,output [2:0] ddr3_ba,
    output ddr3_ras_n,ddr3_cas_n,ddr3_we_n,ddr3_reset_n,
    output [0:0] ddr3_ck_p,ddr3_ck_n,ddr3_cke,ddr3_cs_n,ddr3_odt,
    output [1:0] ddr3_dm
);
    wire core_clk,core_clock_locked,ref_clk_200m;
    generate if(USE_MMCM) begin: multiplied_clock
        board_test_core_clock clock_generator(.ref_clk(sys_clk),.rst_n(sys_rst_n),
            .core_clk(core_clk),.locked(core_clock_locked),.ddr_ref_clk(ref_clk_200m));
    end else begin: bypass_clock
        // Only for legacy simulation with an externally supplied core clock.
        assign core_clk=sys_clk;
        assign ref_clk_200m=sys_clk;
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
    wire mem_cmd_valid,mem_cmd_ready,mem_cmd_write,mem_w_valid,mem_w_ready,mem_w_last;
    wire mem_r_valid,mem_r_ready,mem_r_last,mem_done,mem_error,mem_fault,ddr_fatal,ddr_ready;
    wire [27:0] mem_cmd_addr;wire [13:0] mem_cmd_bytes;
    wire [127:0] mem_w_data,mem_r_data;wire [15:0] mem_w_keep;
    mjpeg_ddr3_memory memory(
        .clk(core_clk),.rst_n(run_rst_n),.ref_clk_200m(ref_clk_200m),
        .cmd_valid(mem_cmd_valid),.cmd_ready(mem_cmd_ready),.cmd_write(mem_cmd_write),.cmd_addr(mem_cmd_addr),.cmd_bytes(mem_cmd_bytes),
        .w_data(mem_w_data),.w_keep(mem_w_keep),.w_valid(mem_w_valid),.w_ready(mem_w_ready),.w_last(mem_w_last),
        .r_data(mem_r_data),.r_valid(mem_r_valid),.r_ready(mem_r_ready),.r_last(mem_r_last),
        .done(mem_done),.error(mem_error),.fatal(ddr_fatal),.ready(ddr_ready),
        .ddr3_dq(ddr3_dq),.ddr3_dqs_n(ddr3_dqs_n),.ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_addr(ddr3_addr),.ddr3_ba(ddr3_ba),.ddr3_ras_n(ddr3_ras_n),.ddr3_cas_n(ddr3_cas_n),
        .ddr3_we_n(ddr3_we_n),.ddr3_reset_n(ddr3_reset_n),.ddr3_ck_p(ddr3_ck_p),.ddr3_ck_n(ddr3_ck_n),
        .ddr3_cke(ddr3_cke),.ddr3_cs_n(ddr3_cs_n),.ddr3_dm(ddr3_dm),.ddr3_odt(ddr3_odt));
    wire [31:0] compressed_fps;
    wire fps_sample_valid;
    wire [15:0] camera_pixel;
    wire camera_valid,camera_sof,camera_eol,camera_eof,camera_abort,camera_ready,camera_take,camera_admit,camera_queue_pressure;
    wire [255:0] camera_status;
    wire camera_admission_enabled;
    wire [3:0] engine_led;
    wire run_requested,board_light_start,board_light_cancel;
    wire [1:0] quality_requested,active_quality;
    wire [7:0] spatial_threshold_requested;
    wire spatial_adaptive_requested;
    wire [7:0] denoise_strength_requested;
    wire [1:0] preprocess_mode_requested;
    wire [7:0] binary_threshold_requested,edge_threshold_requested;
    wire [95:0] preprocess_status;
    generate if(REAL_CAMERA) begin: real_camera
        wire init_done,init_error,capture_active;
        wire light_requested,light_on,light_error,light_busy;
        camera_board_controls #(.CLOCK_HZ(CLOCK_HZ),.SPATIAL_COMMANDS(SPATIAL_SKIP),
            .DENOISE_COMMANDS(DENOISE_ENABLE && CAMERA_PROFILE==5),.PREPROCESS_COMMANDS(PREPROCESS_ENABLE)) controls(
            .clk(core_clk),.reset_n(core_clock_locked),.key_n(key),.rx_data(rx_data),.rx_valid(rx_valid),
            .streaming(engine_led[1]),.camera_ready(camera_ready),.active_quality(active_quality),
            .light_on(light_on),.fault(init_error || light_error || engine_led[3] || ddr_fatal || mem_fault),
            .run_requested(run_requested),.quality_requested(quality_requested),
            .spatial_threshold_requested(spatial_threshold_requested),
            .spatial_adaptive_requested(spatial_adaptive_requested),
            .denoise_strength_requested(denoise_strength_requested),
            .preprocess_mode_requested(preprocess_mode_requested),
            .binary_threshold_requested(binary_threshold_requested),.edge_threshold_requested(edge_threshold_requested),
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
        assign camera_abort=dvp_abort || clock_loss_abort || ddr_fatal || mem_fault;
        ov5640_dvp_capture #(.WIDTH(CAMERA_WIDTH),.HEIGHT(CAMERA_HEIGHT),.YUV_BYTE_ORDER(0),.RAW8(CAMERA_PROFILE==5),.SAMPLE_FALLING(CAMERA_PROFILE>=2),.ADMIT_AT_HREF(1)) capture(
            .pclk(pclk),.rst_n(capture_reset_n),.enable(admit),.cam_vsync(pin_vsync),.cam_href(pin_href),.cam_data(pin_data),
            .core_clk(core_clk),.core_rst_n(capture_reset_n),.s_data(raw_pixel),.s_valid(raw_valid),.s_ready(raw_ready),
            .s_sof(raw_sof),.s_eol(raw_eol),.s_eof(raw_eof),.s_abort(dvp_abort),
            .capture_active(capture_active),.admission_enabled(camera_admission_enabled),.queue_pressure(camera_queue_pressure),.received_frames(received_frames),.dropped_frames(dropped_frames),
            .overflow_count(overflow_count),.frame_sync_count(frame_sync_count),.dvp_byte_count(dvp_byte_count),
            .captured_pixels(captured_pixels),.pclk_ticks(pclk_ticks));
        wire [15:0] converted_pixel;
        wire converted_valid,converted_ready,converted_sof,converted_eol,converted_eof;
        if(CAMERA_PROFILE==5) begin: raw_processing
            // Profile-5 3820=42 aligns optical RAW and ISP channels as BGGR.
            bayer_bggr_to_yuv422 #(.WIDTH(CAMERA_WIDTH),.HEIGHT(CAMERA_HEIGHT),.BAYER_PATTERN(0),.DENOISE_ENABLE(DENOISE_ENABLE)) demosaic(
                .clk(core_clk),.rst_n(capture_reset_n),.abort(camera_abort),
                .cfg_denoise_strength(denoise_strength_requested),
                .s_data(raw_pixel[7:0]),.s_valid(raw_valid),.s_ready(raw_ready),
                .s_sof(raw_sof),.s_eol(raw_eol),.s_eof(raw_eof),
                .m_data(converted_pixel),.m_valid(converted_valid),.m_ready(converted_ready),
                .m_sof(converted_sof),.m_eol(converted_eol),.m_eof(converted_eof));
        end else begin: yuv_processing
            assign converted_pixel=raw_pixel;assign converted_valid=raw_valid;assign raw_ready=converted_ready;
            assign converted_sof=raw_sof;assign converted_eol=raw_eol;assign converted_eof=raw_eof;
        end
        if(PREPROCESS_ENABLE) begin: preprocessing
            wire [1:0] active_mode;
            wire [7:0] active_binary,active_edge;
            wire [31:0] frames_started;
            yuv422_preprocess #(.WIDTH(CAMERA_WIDTH),.HEIGHT(CAMERA_HEIGHT)) processor(
                .clk(core_clk),.rst_n(capture_reset_n),.abort(camera_abort),
                .cfg_mode(preprocess_mode_requested),.cfg_binary_threshold(binary_threshold_requested),
                .cfg_edge_threshold(edge_threshold_requested),
                .s_data(converted_pixel),.s_valid(converted_valid),.s_ready(converted_ready),
                .s_sof(converted_sof),.s_eol(converted_eol),.s_eof(converted_eof),
                .m_data(camera_pixel),.m_valid(camera_valid),.m_ready(camera_take),
                .m_sof(camera_sof),.m_eol(camera_eol),.m_eof(camera_eof),
                .active_mode(active_mode),.active_binary_threshold(active_binary),
                .active_edge_threshold(active_edge),.frames_started(frames_started));
            assign preprocess_status={frames_started,14'd0,active_mode,active_edge,active_binary,
                8'd1,6'd0,preprocess_mode_requested,edge_threshold_requested,binary_threshold_requested};
        end else begin: no_preprocessing
            assign camera_pixel=converted_pixel;assign camera_valid=converted_valid;assign converted_ready=camera_take;
            assign camera_sof=converted_sof;assign camera_eol=converted_eol;assign camera_eof=converted_eof;
            assign preprocess_status=0;
        end
        assign camera_ready=init_done && capture_reset_n && ddr_ready && !mem_fault;
        assign camera_status={dvp_byte_count,overflow_count,dropped_frames,received_frames,pclk_ticks,
            // Configuration bit 11 marks robust YUV denoise v2; bit 10 is
            // adjustable denoise capability. SCCB index remains bits 8:0.
            frame_sync_count[31:16],3'd0,(PREPROCESS_ENABLE!=0),(DENOISE_ENABLE && CAMERA_PROFILE==5),(DENOISE_ENABLE && CAMERA_PROFILE==5),(SPATIAL_SKIP && SPATIAL_ADAPTIVE && SPATIAL_THRESHOLD),reg_index,frame_sync_count[15:0],chip_id,
            (SPATIAL_SKIP && SPATIAL_THRESHOLD!=0),(DENOISE_ENABLE && CAMERA_PROFILE==5)?denoise_strength_requested:spatial_threshold_requested,(quality_requested!=active_quality),quality_requested,active_quality,run_requested,1'b1,
            1'b1,capture_reset_n,(CAMERA_PROFILE==5),1'b1,light_busy,light_error,light_on,light_requested,
            (SPATIAL_ADAPTIVE && spatial_adaptive_requested),1'b0,engine.config_error,engine.busy,engine.tables_ready,capture_active,init_error,init_done};
    end else begin: simulated_camera
        assign camera_pixel=0;assign camera_valid=0;assign camera_sof=0;assign camera_eol=0;assign camera_eof=0;
        assign camera_abort=0;assign camera_ready=1;assign camera_status=0;
        assign camera_admission_enabled=0;
        assign cam_rst_n=0;assign cam_pwdn=1;assign cam_scl=1'bz;assign cam_sda=1'bz;
        assign led=engine_led;
        assign run_requested=0;assign quality_requested=2;
        assign spatial_threshold_requested=0;
        assign spatial_adaptive_requested=0;
        assign denoise_strength_requested=0;
        assign preprocess_mode_requested=0;assign binary_threshold_requested=128;assign edge_threshold_requested=32;
        assign preprocess_status=0;
        assign camera_queue_pressure=0;
        assign board_light_start=0;assign board_light_cancel=0;
    end endgenerate
    mjpeg_board_test_engine #(.CLOCK_HZ(CLOCK_HZ),.SMALL_END(1),.REAL_CAMERA(REAL_CAMERA),.BOARD_CONTROL(REAL_CAMERA),.SPATIAL_SKIP(SPATIAL_SKIP),.SPATIAL_THRESHOLD(SPATIAL_THRESHOLD),.SPATIAL_DDR(1),.SPATIAL_ADAPTIVE(SPATIAL_ADAPTIVE),.PREPROCESS_ENABLE(PREPROCESS_ENABLE && REAL_CAMERA),
        .CAMERA_WIDTH(CAMERA_WIDTH),.CAMERA_HEIGHT(CAMERA_HEIGHT),
        .VGA_WIDTH(VGA_WIDTH),.VGA_HEIGHT(VGA_HEIGHT),.HD_WIDTH(HD_WIDTH),.HD_HEIGHT(HD_HEIGHT),
        .FHD_WIDTH(FHD_WIDTH),.FHD_HEIGHT(FHD_HEIGHT)) engine(
        .mem_cmd_valid(mem_cmd_valid),.mem_cmd_write(mem_cmd_write),.mem_cmd_ready(mem_cmd_ready),.mem_cmd_addr(mem_cmd_addr),
        .mem_cmd_bytes(mem_cmd_bytes),.mem_w_data(mem_w_data),.mem_w_keep(mem_w_keep),.mem_w_valid(mem_w_valid),
        .mem_w_last(mem_w_last),.mem_w_ready(mem_w_ready),.mem_r_data(mem_r_data),.mem_r_valid(mem_r_valid),
        .mem_r_last(mem_r_last),.mem_r_ready(mem_r_ready),.mem_done(mem_done),.mem_error(mem_error),
        .mem_fault(mem_fault),
        .sys_clk(core_clk),.sys_rst_n(run_rst_n),.rx_data(rx_data),.rx_valid(rx_valid),
        .tx_data(engine_tx_data),.tx_valid(engine_tx_valid),.tx_ready(engine_tx_ready),.led(engine_led),
        .camera_pixel(camera_pixel),.camera_valid(camera_valid),.camera_sof(camera_sof),.camera_eol(camera_eol),
        .camera_eof(camera_eof),.camera_abort(camera_abort),.camera_ready(camera_ready),.camera_queue_pressure(camera_queue_pressure),.camera_status(camera_status),.preprocess_status(preprocess_status),
        .camera_admission_enabled(camera_admission_enabled),
        .camera_take(camera_take),.camera_admit(camera_admit),
        .run_requested(run_requested),.quality_requested(quality_requested),.active_quality(active_quality),
        .spatial_threshold_requested(spatial_threshold_requested),
        .spatial_adaptive_requested(spatial_adaptive_requested),
        .compressed_fps(compressed_fps),.fps_sample_valid(fps_sample_valid));
    davinci_fps_display #(.CLOCK_HZ(CLOCK_HZ)) display(
        .clk(core_clk),.rst_n(rst_n),.fps(compressed_fps),.update_valid(fps_sample_valid),
        .seg_sel(seg_sel),.seg_led(seg_led),.bcd_value());
endmodule
