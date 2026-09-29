`timescale 1ns/1ps
// Entire sensor pixel path, real-camera admission, codec, abort recovery and
// final MBLK transport. Uses small images to keep the regression quick.
module tb_mjpeg_board_controls #(parameter SPATIAL_DDR=0,PREPROCESS_ENABLE=0);
    reg clk=0,pclk=0,rst_n=0,vsync=0,href=0;
    always #5 clk=~clk;
    always #20 pclk=~pclk;
    reg [7:0] camera_data=0,rx_data=0;
    reg rx_valid=0,wire_ready=1;
    wire [15:0] pixel;
    wire valid,sof,eol,eof,abort,take,admit,active,admission_enabled;
    wire [31:0] received,dropped,overflows,frames,dvp_bytes,pixels,ticks;
    ov5640_dvp_capture #(.WIDTH(48),.HEIGHT(16),.FIFO_ADDRESS_BITS(8),.YUV_BYTE_ORDER(0)) capture_path(
        .pclk(pclk),.rst_n(rst_n),.enable(admit),.cam_vsync(vsync),.cam_href(href),.cam_data(camera_data),
        .core_clk(clk),.core_rst_n(rst_n),.s_data(pixel),.s_valid(valid),.s_ready(take),
        .s_sof(sof),.s_eol(eol),.s_eof(eof),.s_abort(abort),.capture_active(active),.admission_enabled(admission_enabled),
        .received_frames(received),.dropped_frames(dropped),.overflow_count(overflows),
        .frame_sync_count(frames),.dvp_byte_count(dvp_bytes),.captured_pixels(pixels),.pclk_ticks(ticks));
    wire [3:0] led;
    reg [3:0] keys=15;
    wire run_requested,light_start,light_cancel;
    wire [1:0] quality_requested,active_quality;
    camera_board_controls #(.CLOCK_HZ(20000),.DEBOUNCE_CYCLES(4)) controls(
        .clk(clk),.reset_n(rst_n),.key_n(keys),.rx_data(rx_data),.rx_valid(rx_valid),
        .streaming(led[1]),.camera_ready(1'b1),.active_quality(active_quality),
        .light_on(1'b0),.fault(led[3]),.run_requested(run_requested),
        .quality_requested(quality_requested),.light_start(light_start),.light_cancel(light_cancel),.led());
    wire [7:0] legacy_data,wire_data;
    wire legacy_valid,legacy_ready,wire_valid;
    wire [31:0] fps;
    wire sample;
    wire [31:0] status_flags={26'd0,1'b0,engine.busy,engine.tables_ready,active,1'b0,1'b1}
        | (PREPROCESS_ENABLE?32'h00010000:0)
        | ({30'd0,quality_requested}<<20) | ({30'd0,active_quality}<<18) | ({31'd0,run_requested}<<17);
    wire [255:0] status={dvp_bytes,overflows,dropped,received,ticks,
                        PREPROCESS_ENABLE?32'h00001000:32'd0,32'h5640,status_flags};
    // Different request/active modes exercise pending status and word order.
    wire [95:0] preprocess_status={32'h12345678,32'h00012080,32'h01032080};
    mjpeg_board_test_engine #(.CLOCK_HZ(20000),.SMALL_END(1),.REAL_CAMERA(1),.BOARD_CONTROL(1),.SPATIAL_DDR(SPATIAL_DDR),.PREPROCESS_ENABLE(PREPROCESS_ENABLE),.CAMERA_WIDTH(48),.CAMERA_HEIGHT(16)) engine(
        .sys_clk(clk),.sys_rst_n(rst_n),.rx_data(rx_data),.rx_valid(rx_valid),
        .tx_data(legacy_data),.tx_valid(legacy_valid),.tx_ready(legacy_ready),.led(led),
        .compressed_fps(fps),.fps_sample_valid(sample),
        .camera_pixel(pixel),.camera_valid(valid),.camera_sof(sof),.camera_eol(eol),.camera_eof(eof),
        .camera_abort(abort),.camera_ready(1'b1),.camera_admission_enabled(admission_enabled),
        .camera_status(status),.preprocess_status(preprocess_status),.camera_take(take),.camera_admit(admit),
        .run_requested(run_requested),.quality_requested(quality_requested),.active_quality(active_quality));
    board_test_block_transport blocks(.clk(clk),.rst_n(rst_n),.s_data(legacy_data),.s_valid(legacy_valid),
        .s_ready(legacy_ready),.m_data(wire_data),.m_valid(wire_valid),.m_ready(wire_ready),
        .stats_valid(1'b0),.stats_data(224'd0));
    integer output_file,marker,good_frames=0,bad_frames=0,aborts=0;
    reg [15:0] random_state=16'h172a;
    always @(negedge clk) begin
        random_state={random_state[14:0],random_state[15]^random_state[13]^random_state[12]^random_state[10]};
        wire_ready=random_state[2:0]!=0;
    end
    always @(posedge clk) begin
        if(rst_n && wire_valid && wire_ready) $fwrite(output_file,"%c",wire_data);
        if(engine.rst_n) begin
            if(engine.success_frame) good_frames=good_frames+1;
            if(engine.failed_frame) bad_frames=bad_frames+1;
            if(abort) aborts=aborts+1;
            if(engine.cfg_valid && engine.cfg_ready && (engine.cfg_cmd==2 || engine.cfg_cmd==3) && engine.busy)
                $fatal(1,"Quantizer changed during in-flight JPEG");
            if(admit && (!run_requested || quality_requested!=active_quality))
                $fatal(1,"Frame admission during pending stop/quality change");
        end
    end
    task command(input [7:0] value);
        begin @(negedge clk);rx_data=value;rx_valid=1;@(negedge clk);rx_valid=0;end
    endtask
    task press(input [3:0] mask);
        begin @(negedge clk);keys=15^mask;repeat(12) @(negedge clk);
              keys=15;repeat(12) @(negedge clk);end
    endtask
    task camera_tick;
        begin @(negedge pclk);end
    endtask
    task camera_sync;
        begin
            wait(admit);repeat(8) camera_tick();
            href=0;vsync=1;repeat(6) camera_tick();
            vsync=0;repeat(4) camera_tick();
        end
    endtask
    task camera_line(input integer row,input integer count);
        integer col;
        begin
            for(col=0;col<count;col=col+1) begin
                href=1;camera_data=(3*col+2*row)&255;camera_tick();
                camera_data=col%2?((col/2+3*row+160)&255):((col+row+80)&255);camera_tick();
            end
            href=0;repeat(6) camera_tick();
        end
    endtask
    task camera_frame(input [3:0] midframe_keys);
        integer row;
        begin
            camera_sync();
            for(row=0;row<16;row=row+1) begin
                camera_line(row,48);
                if(midframe_keys!=0 && row==5) begin press(midframe_keys);camera_tick();end
            end
        end
    endtask
    initial begin
        output_file=$fopen("board_controls_capture.bin","wb");
        #33;rst_n=1;repeat(20) @(negedge clk);
        repeat(30) @(negedge clk);if(led[1] || admit) $fatal(1,"Startup must be stopped");
        press(1);
        camera_frame(2);wait(good_frames==1);wait(active_quality==0);
        camera_frame(2);wait(good_frames==2);wait(active_quality==1);
        camera_frame(2);wait(good_frames==3);wait(active_quality==2);
        camera_frame(1);wait(good_frames==4);wait(!led[1]);
        repeat(1000) @(negedge clk);
        press(2);if(quality_requested!=0) $fatal(1,"Stopped quality selection");
        press(9);if(run_requested || admit) $fatal(1,"Simultaneous start/stop priority");
        press(1);camera_frame(0);wait(good_frames==5);
        press(2);wait(engine.state==4);press(8);wait(!led[1]);
        repeat(1000) @(negedge clk);
        press(1);camera_frame(8);wait(good_frames==6);wait(!led[1]);
        repeat(3000) @(negedge clk);
        if(good_frames!=6 || bad_frames!=0 || aborts!=0 || received!=6 || dropped!=0 || overflows!=0)
            $fatal(1,"Control capture counts good=%0d bad=%0d aborts=%0d received=%0d dropped=%0d",good_frames,bad_frames,aborts,received,dropped);
        $fclose(output_file);
        marker=$fopen("BOARD_CONTROLS_SIM_PASS.txt","w");
        $fdisplay(marker,"Board keys -> DVP -> codec -> MBLK: six complete frames, three mid-frame quality changes, mid-frame STOP, stopped quality selection, STOP during table load, clean restart, random downstream stalls passed");
        $fclose(marker);$finish;
    end
    initial begin #3000000;$fatal(1,"Board camera pipeline watchdog state=%0d busy=%b",engine.state,engine.busy);end
endmodule
