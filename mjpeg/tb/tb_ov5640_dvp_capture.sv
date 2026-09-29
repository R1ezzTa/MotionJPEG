`timescale 1ns/1ps
module tb_ov5640_dvp_capture #(parameter YUV_BYTE_ORDER=1,RAW8=0,SAMPLE_FALLING=0,ADMIT_AT_HREF=0);
    reg pclk=0,core_clk=0,rst_n=0,enable=0,vsync=0,href=0;
    reg [7:0] camera_data=0;
    always #20 pclk=~pclk;
    always #5 core_clk=~core_clk;
    reg ready=1,random_stalls=1;
    reg [15:0] stall_random=16'h5ade;
    always @(negedge core_clk) begin
        stall_random={stall_random[14:0],stall_random[15]^stall_random[13]^stall_random[12]^stall_random[10]};
        if(random_stalls) ready=stall_random[2:0]!=0;
    end
    wire [15:0] pixel;
    wire valid,sof,eol,eof,abort,active,admission_enabled;
    wire [31:0] received,dropped,overflows,frames,bytes_count,pixels_count,ticks;
    ov5640_dvp_capture #(.WIDTH(8),.HEIGHT(4),.FIFO_ADDRESS_BITS(4),.YUV_BYTE_ORDER(YUV_BYTE_ORDER),.RAW8(RAW8),.SAMPLE_FALLING(SAMPLE_FALLING),.ADMIT_AT_HREF(ADMIT_AT_HREF)) dut(
        .pclk(pclk),.rst_n(rst_n),.enable(enable),.cam_vsync(vsync),.cam_href(href),.cam_data(camera_data),
        .core_clk(core_clk),.core_rst_n(rst_n),.s_data(pixel),.s_valid(valid),.s_ready(ready),
        .s_sof(sof),.s_eol(eol),.s_eof(eof),.s_abort(abort),.capture_active(active),.admission_enabled(admission_enabled),
        .received_frames(received),.dropped_frames(dropped),.overflow_count(overflows),
        .frame_sync_count(frames),.dvp_byte_count(bytes_count),.captured_pixels(pixels_count),.pclk_ticks(ticks));
    integer expected_id=1,index=0,complete=0,aborts=0,marker,row;
    reg check_pixels=1,held=0;
    reg [18:0] previous_word;
    always @(posedge core_clk) begin
        if(rst_n) begin
            if(abort) begin
                aborts=aborts+1;index=0;held=0;
                if(valid) $fatal(1,"Abort did not flush queued pixels");
            end
            if(held && !dut.fault_req && (!valid || {eof,eol,sof,pixel}!==previous_word))
                $fatal(1,"Pixel changed while consumer stalled");
            held=valid && !ready;previous_word={eof,eol,sof,pixel};
            if(valid && ready && check_pixels) begin
                if(pixel!=={8'(RAW8?128:(128+(index%8))),8'(expected_id*40+index)} ||
                   sof!==(index==0) || eol!==((index%8)==7) || eof!==(index==31))
                    $fatal(1,"Pixel/markers mismatch frame=%0d index=%0d data=%h",expected_id,index,pixel);
                index=index+1;
                if(eof) begin complete=complete+1;index=0;end
            end
        end
    end
    task tick;
        begin if(SAMPLE_FALLING) @(posedge pclk);else @(negedge pclk);end
    endtask
    task sync_frame;
        begin
            href=0;vsync=1;repeat(6) tick();
            vsync=0;repeat(4) tick();
        end
    endtask
    task line(input integer id,input integer row,input integer length);
        integer col;
        begin
            for(col=0;col<length;col=col+1) begin
                if(RAW8) begin href=1;camera_data=id*40+row*8+col;tick();end
                else begin
                    href=1;camera_data=YUV_BYTE_ORDER?(128+col):(id*40+row*8+col);tick();
                    camera_data=YUV_BYTE_ORDER?(id*40+row*8+col):(128+col);tick();
                end
            end
            href=0;repeat(4) tick();
        end
    endtask
    task send_frame(input integer id,input integer lower_enable);
        integer row;
        begin
            sync_frame();
            for(row=0;row<4;row=row+1) begin
                line(id,row,8);
                if(lower_enable && row==0) enable=0;
            end
            repeat(12) tick();
        end
    endtask
    initial begin
        #33;rst_n=1;enable=1;repeat(8) tick();
        // Mid-frame deassertion is an admission change, never a frame abort.
        send_frame(1,1);
        if(complete!=1 || aborts!=0 || received!=1) $fatal(1,"Complete frame/admission latch failed");
        send_frame(2,0);
        if(complete!=1 || dropped!=1) $fatal(1,"Disabled frame was not skipped");
        enable=1;check_pixels=0;repeat(6) tick();
        // Backpressure first fills the FIFO, then aborts atomically.
        random_stalls=0;ready=0;send_frame(3,0);repeat(12) tick();
        if(aborts!=1 || overflows!=1 || valid) $fatal(1,"Overflow did not abort and flush");
        ready=1;random_stalls=1;check_pixels=1;expected_id=4;send_frame(4,0);
        if(complete!=2 || received!=2 || aborts!=1) $fatal(1,"Recovery after overflow failed");
        // A short DVP line must not silently create a shifted JPEG frame.
        check_pixels=0;sync_frame();line(5,0,3);repeat(12) tick();
        if(aborts!=2 || overflows!=1 || valid) $fatal(1,"Broken line not aborted");
        check_pixels=1;expected_id=5;send_frame(5,0);
        if(complete!=3 || received!=3 || aborts!=2 || dropped!=3 || frames!=6 || ticks==0 || bytes_count==0)
            $fatal(1,"Camera recovery/counters failed received=%0d dropped=%0d frames=%0d",received,dropped,frames);
        // STOP can reach core on exactly the sensor VSYNC falling edge. The
        // PCLK domain may already have admitted that frame: its active flag
        // must be visible before disable acknowledgement returns to core.
        expected_id=6;vsync=1;repeat(6) tick();
        vsync=0;enable=0;repeat(4) tick();
        if(admission_enabled || active!==!ADMIT_AT_HREF) $fatal(1,"VSYNC-boundary stop acknowledgement raced capture_active");
        for(row=0;row<4;row=row+1) line(6,row,8);
        repeat(12) tick();
        if(complete!=(ADMIT_AT_HREF?3:4) || received!=(ADMIT_AT_HREF?3:4) || active || admission_enabled)
            $fatal(1,"VSYNC-boundary stop did not drain the admitted frame");
        if(ADMIT_AT_HREF) begin
            if(dropped!=4) $fatal(1,"Stop before first HREF must reject the whole frame");
            // Simulate a previous codec frame still busy at VSYNC falling,
            // then becoming available during the porch before the first byte.
            expected_id=7;enable=0;sync_frame();
            if(active || !dut.admission_pending || dropped!=4) $fatal(1,"VSYNC must arm without early rejection");
            enable=1;repeat(6) tick();
            for(row=0;row<4;row=row+1) begin
                line(7,row,8);if(row==0) enable=0;
            end
            repeat(12) tick();
            if(complete!=4 || received!=4 || dropped!=4 || aborts!=2)
                $fatal(1,"Late HREF admission lost byte zero or unlocked mid-frame");
            // Busy on the first byte rejects the whole frame. Becoming ready
            // on its second row must not admit a partial image.
            sync_frame();line(8,0,8);enable=1;repeat(6) tick();
            for(row=1;row<4;row=row+1) line(8,row,8);
            repeat(12) tick();
            if(complete!=4 || dropped!=5 || aborts!=2 || valid) $fatal(1,"Rejected frame was joined mid-frame");
            // STOP after arming but before HREF is acknowledged without an
            // active frame; the first HREF performs the single drop count.
            sync_frame();enable=0;repeat(6) tick();
            if(active || admission_enabled) $fatal(1,"Porch stop acknowledgement failed");
            for(row=0;row<4;row=row+1) line(9,row,8);
            repeat(12) tick();
            if(complete!=4 || dropped!=6 || aborts!=2) $fatal(1,"Porch STOP admission failed");
            // An armed frame without any HREF expires at the next VSYNC and
            // cannot contaminate the next admission or flush recovery.
            sync_frame();vsync=1;repeat(6) tick();
            if(dut.admission_pending || dropped!=7) $fatal(1,"Empty armed frame did not expire");
            enable=1;expected_id=10;send_frame(10,0);
            if(complete!=5 || received!=5 || dropped!=7 || aborts!=2)
                $fatal(1,"Recovery after late-admission rejects failed");
        end
        marker=$fopen("CAMERA_CAPTURE_PASS.txt","w");
        $fdisplay(marker,"YUV_BYTE_ORDER=%0d RAW8=%0d SAMPLE_FALLING=%0d ADMIT_AT_HREF=%0d: complete pixels/markers, random stalls, admission locking, disabled-frame skip, STOP acknowledgement, FIFO overflow flush/abort, malformed-line recovery, optional porch-to-first-HREF admission/rejection and byte-zero preservation passed",YUV_BYTE_ORDER,RAW8,SAMPLE_FALLING,ADMIT_AT_HREF);
        $fclose(marker);$finish;
    end
    initial begin #1000000;$fatal(1,"Timeout");end
endmodule
