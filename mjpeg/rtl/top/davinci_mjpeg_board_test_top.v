// Internal YUYV camera substitute -> existing MJPEG -> byte transport.
// G: nine small frames; C: continuous small frames; V/H/F: VGA/720p/1080p
// continuous colour ramp. S: stop after the current frame.
// Response: "MJBT", then fixed 5-byte records {LE32 word, flags}.
// flags[2:0]=valid bytes, flags[3]=packet_last. All other bits are zero.
// Periodic telemetry uses flags 0x80..0x85 and may appear between bus records.
module mjpeg_board_test_engine #(
    parameter CLOCK_HZ=50000000,VGA_WIDTH=640,VGA_HEIGHT=480,
    HD_WIDTH=1280,HD_HEIGHT=720,FHD_WIDTH=1920,FHD_HEIGHT=1080
)(
    input sys_clk, sys_rst_n,
    input [7:0] rx_data, input rx_valid,
    output reg [7:0] tx_data, output reg tx_valid, input tx_ready,
    output [3:0] led,
    output [31:0] compressed_fps,output fps_sample_valid
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
    wire start;
    wire [15:0] width=(resolution==1)?VGA_WIDTH:(resolution==2)?HD_WIDTH:(resolution==3)?FHD_WIDTH:
                             (test_case==1)?16'd32:16'd16;
    wire [15:0] height=(resolution==1)?VGA_HEIGHT:(resolution==2)?HD_HEIGHT:(resolution==3)?FHD_HEIGHT:
                              (test_case==0)?16'd16:((test_case==1)?16'd24:16'd8);
    wire [21:0] pixel_count=(resolution==1)?VGA_WIDTH*VGA_HEIGHT:(resolution==2)?HD_WIDTH*HD_HEIGHT:(resolution==3)?FHD_WIDTH*FHD_HEIGHT:
                                  (test_case==0)?22'd256:((test_case==1)?22'd768:22'd128);
    wire [10:0] pixel_base=(test_case==0) ? 11'd0 : ((test_case==1) ? 11'd256 : 11'd1024);
    (* rom_style="block" *) reg [15:0] pixels[0:1151];
    (* rom_style="block" *) reg [28:0] quant[0:383];
    reg [15:0] pixel;
    wire [15:0] gradient_pixel;
    board_test_gradient gradient(.x(x),.y(y),.pixel(gradient_pixel));
    reg [28:0] q;
    initial begin
        $readmemh("data/board_test/pixels.mem",pixels);
        $readmemh("data/board_test/quant.mem",quant);
    end
    always @(posedge sys_clk) begin
        if (state==PREAD) pixel<=(resolution!=0)?gradient_pixel:pixels[pixel_base+pixel_index[10:0]];
        if (state==QREAD) q<=quant[(resolution!=0)?{2'd0,q_index}:{test_case,q_index}];
    end
    reg [2:0] cfg_cmd;
    reg [31:0] cfg_data;
    reg cfg_valid;
    wire cfg_ready, s_ready, busy, tables_ready, config_error;
    always @* begin
        cfg_valid=1; cfg_cmd=0; cfg_data=0;
        case (state)
            DIM: begin cfg_cmd=0; cfg_data={height,width}; end
            MODE: begin cfg_cmd=1; cfg_data=(resolution==0 && test_case==0)?32'd3:32'd1; end
            QVALUE: begin cfg_cmd=2; cfg_data={17'd0,q[7:0],q_index}; end
            QRECIP: begin cfg_cmd=3; cfg_data={11'd0,q[28:8]}; end
            default: cfg_valid=0;
        endcase
    end
    wire [31:0] m_data;
    wire [2:0] m_bytes;
    wire m_valid, m_ready, m_packet_last;
    mjpeg_synth_top #(.CHANNELS(1),.MAX_WIDTH(1920),.COALESCE(1)) codec(
        .clk(sys_clk),.rst_n(rst_n),.cfg_cmd(cfg_cmd),.cfg_channel(2'd0),
        .cfg_data(cfg_data),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),
        .s_data(pixel),.s_valid(state==PSEND),.s_ready(s_ready),
        .s_sof(pixel_index==0),.s_eol(x==width-1),.s_eof(pixel_index==pixel_count-1),.s_abort(1'b0),
        .m_data(m_data),.m_bytes(m_bytes),.m_valid(m_valid),.m_ready(m_ready),
        .m_packet_last(m_packet_last),.busy(busy),.tables_ready(tables_ready),.config_error(config_error));

    // The byte transport stalls this boundary; JPEG bytes are never substituted.
    reg [39:0] record;
    reg [2:0] remaining, preamble;
    reg [2:0] packet_index;
    reg descriptor;
    reg telemetry_pending,telemetry_active;
    reg timing_pending,timing_active;
    reg end_pending;
    assign m_ready=(state!=IDLE) && preamble==0 && remaining==0 &&
                   !telemetry_active && !telemetry_pending && !timing_active && !timing_pending;
    wire word_taken=m_valid && m_ready;
    wire descriptor_done=word_taken && m_packet_last && descriptor;
    wire input_frame=(state==PSEND) && s_ready && pixel_index==0;
    wire success_frame=descriptor_done && m_data[7:0]==0;
    wire failed_frame=descriptor_done && m_data[7:0]!=0;
    wire [31:0] fps_window_id,input_fps,failed_fps,total_compressed;
    frame_rate_meter #(.CLOCK_HZ(CLOCK_HZ)) meter(
        .clk(sys_clk),.rst_n(rst_n),.input_frame(input_frame),.success_frame(success_frame),.failed_frame(failed_frame),
        .sample_valid(fps_sample_valid),.window_id(fps_window_id),.input_fps(input_fps),
        .compressed_fps(compressed_fps),.failed_fps(failed_fps),.total_compressed(total_compressed));
    assign start=(state==IDLE) && command_pending && remaining==0 && preamble==0 &&
                 !telemetry_active && !telemetry_pending && !timing_active && !timing_pending && !end_pending && tx_ready;
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
            if(!telemetry_active && !timing_active && telemetry_pending && remaining==0 && preamble==0 && !start) begin
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
                frame_measured<=resolution!=0;
            end
            if(frame_measured) begin
                if(state==PSEND && !s_ready) input_wait<=input_wait+1'b1;
                if(m_valid && !m_ready) output_wait<=output_wait+1'b1;
                if(state==PSEND && s_ready && pixel_index==pixel_count-1) feed_ticks<=timebase-frame_start_tick;
                if(word_taken && m_packet_last && !descriptor && last_payload) jpeg_ticks<=timebase-frame_start_tick;
            end
            if(word_taken && packet_index==0) last_payload<=m_data[11:10]==0 && m_data[6];
            if(word_taken && packet_index==1 && descriptor) timing_frame_id<=m_data;
            if(descriptor_done && frame_measured) begin
                frame_measured<=0;timing_pending<=1;
                report_id<=timing_frame_id;report_feed<=feed_ticks;report_jpeg<=jpeg_ticks;
                report_total<=timebase-frame_start_tick;report_input_wait<=input_wait;report_output_wait<=output_wait;
            end
            if(!timing_active && timing_pending && remaining==0 && preamble==0 &&
               !telemetry_active && !telemetry_pending && !start) begin
                timing_active<=1;timing_pending<=0;timing_index<=0;
            end
            if(timing_active && remaining==0) begin
                if(timing_index==6) begin timing_active<=0;timing_index<=0; end
                else timing_index<=timing_index+1'b1;
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
            if(state==FINISH && remaining==0 && tx_ready && !m_valid && !busy &&
               !telemetry_active && !telemetry_pending && !timing_active && !timing_pending)
                end_pending<=resolution!=0;
            if(end_pending && remaining==0 && !telemetry_active && !telemetry_pending && !timing_active && !timing_pending) begin
                record<={8'ha0,32'h31444e45};remaining<=5;end_pending<=0; // END1
            end
        end
    end
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; test_case<=0; round_no<=0; q_index<=0; pixel_index<=0; x<=0;y<=0; done<=0; error_seen<=0;
            resolution<=0;pending_resolution<=0;
            continuous<=0;stop_requested<=0;command_pending<=0;pending_continuous<=0;
        end else begin
            if(rx_valid && state==IDLE && (rx_data=="G" || rx_data=="C" || rx_data=="V" || rx_data=="H" || rx_data=="F")) begin
                command_pending<=1;pending_continuous<=rx_data!="G";
                pending_resolution<=(rx_data=="V")?1:(rx_data=="H")?2:(rx_data=="F")?3:0;
            end
            if(rx_valid && rx_data=="S" && state!=IDLE) stop_requested<=1;
            if (config_error && (state==PSEND || state==WAIT_DESC)) error_seen<=1;
            if (descriptor_done && m_data[7:0]!=0) error_seen<=1;
            case (state)
                IDLE: if (start) begin
                    state<=DIM;test_case<=0;round_no<=0;done<=0;error_seen<=0;
                    continuous<=pending_continuous;resolution<=pending_resolution;stop_requested<=0;command_pending<=0;
                end
                DIM: if (cfg_ready) state<=MODE;
                MODE: if (cfg_ready) begin state<=QREAD; q_index<=0; end
                QREAD: state<=QVALUE;
                QVALUE: if (cfg_ready) state<=QRECIP;
                QRECIP: if (cfg_ready) begin
                    if (q_index==127) state<=TABLES;
                    else begin q_index<=q_index+1'b1; state<=QREAD; end
                end
                TABLES: if (tables_ready && !config_error) begin pixel_index<=0; x<=0;y<=0; state<=PREAD; end
                PREAD: state<=PSEND;
                PSEND: if (s_ready) begin
                    if (pixel_index==pixel_count-1) state<=WAIT_DESC;
                    else begin
                        pixel_index<=pixel_index+1'b1;
                        if(x==width-1) begin x<=0;y<=y+1'b1; end else x<=x+1'b1;
                        state<=PREAD;
                    end
                end
                WAIT_DESC: if (descriptor_done) begin
                    if(stop_requested || (rx_valid && rx_data=="S")) state<=FINISH;
                    else if(resolution!=0) state<=DIM;
                    else if (test_case==2) begin
                        if(continuous) begin test_case<=0;state<=DIM; end
                        else
                        if (round_no==2) state<=FINISH;
                        else begin round_no<=round_no+1'b1; test_case<=0; state<=DIM; end
                    end else begin test_case<=test_case+1'b1; state<=DIM; end
                end
                FINISH: if (remaining==0 && tx_ready && !m_valid && !busy && !telemetry_active && !telemetry_pending &&
                           !timing_active && !timing_pending) begin state<=IDLE; done<=1; end
                default: state<=IDLE;
            endcase
        end
    end
    assign led={error_seen,done,(state!=IDLE),tables_ready};
endmodule

// Physical board top, using FT232H's existing asynchronous FT245 FIFO mode.
module davinci_mjpeg_board_test_top #(parameter CLOCK_HZ=50000000)(
    input sys_clk, sys_rst_n,
    inout [7:0] usb_data,
    input usb_rxf_n, usb_txe_n,
    output usb_rd_n, usb_wr_n, usb_oe_n, usb_siwu_n,
    output [3:0] led,output [5:0] seg_sel,output [7:0] seg_led
);
    wire [7:0] rx_data,tx_data;
    wire rx_valid,tx_valid,tx_ready;
    wire rst_n;
    (* ASYNC_REG="TRUE" *) reg [2:0] reset_pipe=0;
    always @(posedge sys_clk or negedge sys_rst_n)
        if (!sys_rst_n) reset_pipe<=0;
        else reset_pipe<={reset_pipe[1:0],1'b1};
    assign rst_n=reset_pipe[2];
    board_test_ft245_async link(
        .clk(sys_clk),.rst_n(rst_n),.usb_data(usb_data),.usb_rxf_n(usb_rxf_n),.usb_txe_n(usb_txe_n),
        .usb_rd_n(usb_rd_n),.usb_wr_n(usb_wr_n),.usb_oe_n(usb_oe_n),.usb_siwu_n(usb_siwu_n),
        .rx_data(rx_data),.rx_valid(rx_valid),.tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready));
    wire [31:0] compressed_fps;
    wire fps_sample_valid;
    mjpeg_board_test_engine #(.CLOCK_HZ(CLOCK_HZ)) engine(
        .sys_clk(sys_clk),.sys_rst_n(sys_rst_n),.rx_data(rx_data),.rx_valid(rx_valid),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.led(led),
        .compressed_fps(compressed_fps),.fps_sample_valid(fps_sample_valid));
    davinci_fps_display #(.CLOCK_HZ(CLOCK_HZ)) display(
        .clk(sys_clk),.rst_n(rst_n),.fps(compressed_fps),.update_valid(fps_sample_valid),
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
