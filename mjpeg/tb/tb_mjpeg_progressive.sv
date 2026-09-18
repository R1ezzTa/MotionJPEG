`timescale 1ns/1ps
// Scaled dimensions exercise all three commands, row banks, stalls, timings
// and frame-boundary stops. Full sizes are verified on the actual board.
module tb_mjpeg_progressive;
    reg clk=0,rst_n=0,rx_valid=0;
    reg [7:0] rx_data=0;
    always #10 clk=~clk;
    wire [7:0] tx_data;
    wire tx_valid;
    wire [7:0] block_data;
    wire block_valid,engine_ready;
    wire [3:0] led;
    integer cycles=0,completed=0,capture,trace,marker;
    reg tx_ready=1;
    always @(negedge clk) tx_ready=(cycles%19)<15;
    mjpeg_board_test_engine #(.CLOCK_HZ(10000),.VGA_WIDTH(48),.VGA_HEIGHT(16),
        .HD_WIDTH(64),.HD_HEIGHT(24),.FHD_WIDTH(96),.FHD_HEIGHT(32)) dut(
        .sys_clk(clk),.sys_rst_n(rst_n),.rx_data(rx_data),.rx_valid(rx_valid),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(engine_ready),.led(led),.compressed_fps(),.fps_sample_valid());
    board_test_block_transport blocks(.clk(clk),.rst_n(dut.rst_n),
        .s_data(tx_data),.s_valid(tx_valid),.s_ready(engine_ready),
        .m_data(block_data),.m_valid(block_valid),.m_ready(tx_ready),.stats_valid(1'b0),.stats_data(224'd0));
    reg [15:0] gx=0,gy=0;
    wire [15:0] gp;
    board_test_gradient generator(.x(gx),.y(gy),.pixel(gp));
    integer reference_x=0,reference_y=0;
    integer tick=0,start_tick=0,feed_tick=0,jpeg_tick=0,wait_in=0,wait_out=0;
    integer packet_word=0,packet_id=0;
    reg packet_descriptor=0,packet_last_payload=0,inflight=0;
    reg pixel_stalled=0,feeding=0;
    reg [18:0] held_pixel;
    integer pixel_stall_cycles=0,accepted_pixels=0;
    reg [7:0] expected_y,expected_c;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>1000000) $fatal(1,"Progressive watchdog");
        if(dut.rst_n) begin
            if(block_valid && tx_ready) $fwrite(capture,"%c",block_data);
            if(led[3]) $fatal(1,"Unexpected codec error");
            if(pixel_stalled && (!dut.codec.s_valid ||
               {dut.codec.s_eof,dut.codec.s_eol,dut.codec.s_sof,dut.codec.s_data}!==held_pixel))
                $fatal(1,"Pixel or raster markers changed under backpressure");
            if(feeding && !dut.codec.s_valid) $fatal(1,"Bubble in one-cycle pixel supply");
            pixel_stalled=dut.codec.s_valid && !dut.codec.s_ready;
            held_pixel={dut.codec.s_eof,dut.codec.s_eol,dut.codec.s_sof,dut.codec.s_data};
            pixel_stall_cycles=pixel_stall_cycles+pixel_stalled;
            if(dut.codec.s_valid && dut.codec.s_ready) begin
                if(dut.codec.s_sof) begin
                    reference_x=0;reference_y=0;start_tick=tick;inflight=1;
                    wait_in=0;wait_out=0;feed_tick=0;jpeg_tick=0;
                    feeding=1;accepted_pixels=0;
                end
                accepted_pixels=accepted_pixels+1;
                expected_y=(3*reference_x+2*reference_y)&255;
                expected_c=reference_x%2 ? (reference_x/2+3*reference_y+160)&255 : (reference_x+reference_y+80)&255;
                if(dut.codec.s_data!=={expected_c,expected_y}) $fatal(1,"Gradient changed under stalls or coordinate error");
                if(dut.codec.s_eol!==(reference_x==dut.width-1) ||
                   dut.codec.s_eof!==((reference_x==dut.width-1)&&(reference_y==dut.height-1))) $fatal(1,"Raster frame markers");
                if(dut.codec.s_eof) begin
                    feed_tick=tick-start_tick;feeding=0;
                    if(accepted_pixels!=dut.width*dut.height ||
                       feed_tick-wait_in!=dut.width*dut.height-1) $fatal(1,"One-cycle pixel cadence/count");
                end
                if(reference_x==dut.width-1) begin reference_x=0;reference_y=reference_y+1; end
                else reference_x=reference_x+1;
            end
            if(inflight) begin
                if(dut.codec.s_valid && !dut.codec.s_ready) wait_in=wait_in+1;
                if(dut.m_valid && !dut.m_ready) wait_out=wait_out+1;
            end
            if(dut.m_valid && dut.m_ready) begin
                if(packet_word==0) begin
                    packet_descriptor=dut.m_data[11:10]==1;
                    packet_last_payload=dut.m_data[11:10]==0 && dut.m_data[6];
                end
                if(packet_word==1) packet_id=dut.m_data;
                if(dut.m_packet_last) begin
                    if(packet_descriptor) begin
                        if(!inflight || dut.m_data[7:0]!=0) $fatal(1,"Frame completion/status");
                        if(completed!=0) $fwrite(trace,",\n");
                        $fwrite(trace,"{\"frame_id\":%0d,\"feed_ticks\":%0d,\"jpeg_ticks\":%0d,\"total_ticks\":%0d,\"input_wait_ticks\":%0d,\"output_wait_ticks\":%0d}",
                            packet_id,feed_tick,jpeg_tick,tick-start_tick,wait_in,wait_out);
                        completed=completed+1;inflight=0;
                    end else if(packet_last_payload) jpeg_tick=tick-start_tick;
                    packet_word=0;
                end else packet_word=packet_word+1;
            end
            tick=tick+1;
        end
    end
    task command(input [7:0] cmd);
        begin @(negedge clk);rx_data=cmd;rx_valid=1;@(negedge clk);rx_valid=0; end
    endtask
    task run_phase(input [7:0] cmd,input integer target);
        begin
            command(cmd);wait(!led[2]);wait(completed==target-1);
            wait(dut.codec.s_valid && dut.codec.s_ready && dut.codec.s_sof);
            command("S");wait(led[2]);
            if(completed!=target) $fatal(1,"Stop must finish the second frame");
            repeat(32000) @(negedge clk);
        end
    endtask
    integer a,b;
    initial begin
        capture=$fopen("progressive_capture.bin","wb");trace=$fopen("timing_expected.json","w");$fwrite(trace,"[\n");
        // Check the generator at actual full-HD edges and wrap boundaries.
        for(a=0;a<1920;a=a+1) begin
            gx=a;
            for(b=0;b<4;b=b+1) begin
                gy=(b==0)?0:(b==1)?479:(b==2)?719:1079;#1;
                expected_y=(3*a+2*gy)&255;
                expected_c=a%2 ? (a/2+3*gy+160)&255 : (a+gy+80)&255;
                if(gp!=={expected_c,expected_y}) $fatal(1,"Full-HD generator boundary");
            end
        end
        repeat(10) @(negedge clk);rst_n=1;repeat(10) @(negedge clk);
        run_phase("V",2);run_phase("H",4);run_phase("F",6);
        wait(dut.remaining==0 && !dut.telemetry_active && !dut.telemetry_pending && !dut.end_pending &&
            blocks.out_state==0 && !blocks.control_pending && blocks.bank_ready==0 && !blocks.record_pending);
        $fwrite(trace,"\n]\n");$fclose(trace);$fclose(capture);
        marker=$fopen("PROGRESSIVE_SIM_PASS.txt","w");
        $fdisplay(marker,"Six one-cycle graduated frames, full pixel count/cadence, stable data/markers during %0d stalled input cycles, stop and independent frame timings passed",pixel_stall_cycles);
        $fclose(marker);$finish;
    end
endmodule
