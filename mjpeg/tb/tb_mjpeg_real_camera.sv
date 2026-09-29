`timescale 1ns/1ps
// Entire sensor pixel path, real-camera admission, codec, abort recovery and
// final MBLK transport. Uses small images to keep the regression quick.
module tb_mjpeg_real_camera #(parameter ADMIT_AT_HREF=0);
    reg clk=0,pclk=0,rst_n=0,vsync=0,href=0;
    always #5 clk=~clk;
    always #20 pclk=~pclk;
    reg [7:0] camera_data=0,rx_data=0;
    reg rx_valid=0,wire_ready=1;
    wire [15:0] pixel;
    wire valid,sof,eol,eof,abort,take,admit,active,admission_enabled;
    wire [31:0] received,dropped,overflows,frames,dvp_bytes,pixels,ticks;
    ov5640_dvp_capture #(.WIDTH(48),.HEIGHT(16),.FIFO_ADDRESS_BITS(8),.YUV_BYTE_ORDER(0),.ADMIT_AT_HREF(ADMIT_AT_HREF)) capture_path(
        .pclk(pclk),.rst_n(rst_n),.enable(admit),.cam_vsync(vsync),.cam_href(href),.cam_data(camera_data),
        .core_clk(clk),.core_rst_n(rst_n),.s_data(pixel),.s_valid(valid),.s_ready(take),
        .s_sof(sof),.s_eol(eol),.s_eof(eof),.s_abort(abort),.capture_active(active),.admission_enabled(admission_enabled),
        .received_frames(received),.dropped_frames(dropped),.overflow_count(overflows),
        .frame_sync_count(frames),.dvp_byte_count(dvp_bytes),.captured_pixels(pixels),.pclk_ticks(ticks));
    wire [3:0] led;
    wire [7:0] legacy_data,wire_data;
    wire legacy_valid,legacy_ready,wire_valid;
    wire [31:0] fps;
    wire sample;
    wire [255:0] status={dvp_bytes,overflows,dropped,received,ticks,32'd0,32'h5640,
                        26'd0,1'b0,engine.busy,engine.tables_ready,active,1'b0,1'b1};
    mjpeg_board_test_engine #(.CLOCK_HZ(20000),.SMALL_END(1),.REAL_CAMERA(1),.CAMERA_WIDTH(48),.CAMERA_HEIGHT(16)) engine(
        .sys_clk(clk),.sys_rst_n(rst_n),.rx_data(rx_data),.rx_valid(rx_valid),
        .tx_data(legacy_data),.tx_valid(legacy_valid),.tx_ready(legacy_ready),.led(led),
        .compressed_fps(fps),.fps_sample_valid(sample),
        .camera_pixel(pixel),.camera_valid(valid),.camera_sof(sof),.camera_eol(eol),.camera_eof(eof),
        .camera_abort(abort),.camera_ready(1'b1),.camera_admission_enabled(admission_enabled),
        .camera_status(status),.camera_take(take),.camera_admit(admit));
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
        end
    end
    task command(input [7:0] value);
        begin @(negedge clk);rx_data=value;rx_valid=1;@(negedge clk);rx_valid=0;end
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
    task camera_frame(input integer stop_midframe);
        integer row;
        begin
            camera_sync();
            for(row=0;row<16;row=row+1) begin
                camera_line(row,48);
                if(stop_midframe && row==5) begin command("S");camera_tick();end
            end
        end
    endtask
    initial begin
        output_file=$fopen("real_camera_capture.bin","wb");
        #33;rst_n=1;repeat(20) @(negedge clk);command("C");
        camera_frame(0);wait(good_frames==1);
        camera_frame(0);wait(good_frames==2);
        camera_sync();camera_line(0,13);wait(bad_frames==1);
        camera_frame(1);wait(good_frames==3);wait(led[2] && !led[1]);
        repeat(3000) @(negedge clk);
        if(good_frames!=3 || bad_frames!=1 || aborts!=1 || received!=3 || dropped!=1 || overflows!=0)
            $fatal(1,"Real capture counts good=%0d bad=%0d aborts=%0d received=%0d dropped=%0d",good_frames,bad_frames,aborts,received,dropped);
        $fclose(output_file);
        marker=$fopen("REAL_CAMERA_SIM_PASS.txt","w");
        $fdisplay(marker,"ADMIT_AT_HREF=%0d DVP YUYV -> CDC -> real-camera engine -> MBLK: 3 complete 48x16 frames, 1 short-line abort, recovery, STOP during active frame, random downstream stalls passed",ADMIT_AT_HREF);
        $fclose(marker);$finish;
    end
    initial begin #1000000;$fatal(1,"Real camera pipeline watchdog state=%0d busy=%b",engine.state,engine.busy);end
endmodule
