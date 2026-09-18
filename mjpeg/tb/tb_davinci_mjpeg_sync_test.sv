`timescale 1ns/1ps
// Independent FT232H peer: flags and read data change 9ns after CLKOUT.
// Checks full-cycle setup, actual TXE/RXF-qualified transfers and turnaround.
module tb_davinci_mjpeg_sync_test #(parameter PROGRESSIVE=0);
    reg clk=0,usb_clk=0,rst_n=0,txe_n=1,rxf_n=1;
    always #10 clk=~clk;
    initial begin #2.137;forever #8.333 usb_clk=~usb_clk;end
    wire [7:0] data;
    wire rd_n,wr_n,oe_n,siwu_n;
    wire [3:0] led;
    wire [5:0] seg_sel;
    wire [7:0] seg_led;
    reg [7:0] commands[0:255],peer_data=0;
    integer command_write=0,command_read=0,usb_cycles=0,bytes_seen=0;
    integer capture,marker,rate_trace,link_trace,timing_trace;
    integer completed=0,monitor_ticks=0,monitor_in=0,monitor_ok=0,monitor_total=0,monitor_windows=0;
    integer link_ticks=0,link_writes=0,read_bytes=0,longest_burst=0,burst=0,blocked_bytes=0;
    reg previous_cycle=0,previous_write=0;
    real data_changed=0,wr_changed=0,rd_changed=0,oe_changed=0,oe_low=0;
    real tristate_changed=0;
    wire core_clk=dut.core_clk;
    assign data=!oe_n?peer_data:8'bz;
    davinci_mjpeg_board_test_top #(.CLOCK_HZ(24000),.USB_CLOCK_HZ(14400),
        .VGA_WIDTH(48),.VGA_HEIGHT(16),.HD_WIDTH(64),.HD_HEIGHT(24),.FHD_WIDTH(96),.FHD_HEIGHT(32)) dut(
        .sys_clk(clk),.sys_rst_n(rst_n),.usb_clk_60m(usb_clk),.usb_data(data),
        .usb_rxf_n(rxf_n),.usb_txe_n(txe_n),.usb_rd_n(rd_n),.usb_wr_n(wr_n),
        .usb_oe_n(oe_n),.usb_siwu_n(siwu_n),.led(led),.seg_sel(seg_sel),.seg_led(seg_led));
    always @(data) data_changed=$realtime;
    always @(wr_n) wr_changed=$realtime;
    always @(rd_n) rd_changed=$realtime;
    always @(oe_n) begin oe_changed=$realtime;if(!oe_n) oe_low=$realtime;end
    always @(dut.synchronous.link.tristate_n) tristate_changed=$realtime;
    always @(negedge oe_n) if(rst_n && (dut.synchronous.link.tristate_n!==8'hff ||
        $realtime-tristate_changed<16.660)) $fatal(1,"FPGA must release bus one clock before FTDI OE");
    always @(negedge rd_n) if(rst_n && ($realtime-oe_low<16.660 || oe_n))
        $fatal(1,"OE must precede RD by one whole CLKOUT");
    always @(posedge usb_clk) begin
        usb_cycles=usb_cycles+1;
        if(usb_cycles>1500000) $fatal(1,"Sync board watchdog");
        if(dut.synchronous.usb_rst_n) begin
            // Stats arithmetic is pipelined one cycle after the physical edge.
            // Count independently observed previous edge, not DUT handshakes.
            if(previous_cycle) begin link_ticks=link_ticks+1;link_writes=link_writes+previous_write;end
            previous_cycle=1;previous_write=!wr_n && !txe_n;
            if(!wr_n && !txe_n) begin
                if(!oe_n || !rd_n || $isunknown(data)) $fatal(1,"Write bus collision");
                if($realtime-tristate_changed<33.320)
                    $fatal(1,"T must enable two CLKOUT periods before first physical write");
                if($realtime-data_changed<7.5 || $realtime-wr_changed<7.5)
                    $fatal(1,"Synchronous DATA/WR setup <7.5ns");
                $fwrite(capture,"%c",data);bytes_seen=bytes_seen+1;
                burst=burst+1;if(burst>longest_burst) longest_burst=burst;
            end else begin burst=0;if(!wr_n && txe_n) blocked_bytes=blocked_bytes+1;end
            if(!rd_n && !rxf_n) begin
                if(oe_n || !wr_n || $realtime-rd_changed<7.5 || $realtime-oe_changed<7.5)
                    $fatal(1,"Synchronous read/turnaround/setup");
                command_read=command_read+1;read_bytes=read_bytes+1;
            end
            #0.001;
            if(dut.synchronous.usb_stats_valid) begin
                if(link_ticks!=14400 || dut.synchronous.usb_stats_data[95:64]!=link_writes ||
                    dut.synchronous.usb_stats_data[63:32]!=link_ticks) $fatal(1,"Physical write counter mismatch");
                $fwrite(link_trace,"%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",dut.synchronous.usb_stats_data[31:0],link_ticks,
                    link_writes,dut.synchronous.usb_stats_data[127:96],dut.synchronous.usb_stats_data[159:128],
                    dut.synchronous.usb_stats_data[191:160],dut.synchronous.usb_stats_data[223:192]);
                link_ticks=0;link_writes=0;
            end
        end
        // Worst specified output delay; include both short and long TX stalls.
        #8.999;
        txe_n=(usb_cycles%97<11 || usb_cycles%11000<1800);
        rxf_n=command_read==command_write;
        peer_data=commands[command_read];
    end
    integer tick=0,start_tick=0,feed_tick=0,jpeg_tick=0,wait_in=0,wait_out=0;
    integer packet_word=0,packet_id=0,px=0,py=0;
    reg descriptor=0,last_payload=0,inflight=0,pixel_stalled=0;
    reg [18:0] held_pixel;
    reg [7:0] expected_y,expected_c;
    real previous_core_edge=0;
    integer checked_core_edges=0;
    always @(posedge core_clk) if(dut.core_clock_locked) begin
        if(previous_core_edge!=0 && $realtime-previous_core_edge!=10.000)
            $fatal(1,"MMCM core period must be 10ns (100MHz)");
        previous_core_edge=$realtime;checked_core_edges=checked_core_edges+1;
    end
    always @(posedge core_clk) if(dut.engine.rst_n) begin
        monitor_ticks=monitor_ticks+1;monitor_in=monitor_in+dut.engine.input_frame;
        monitor_ok=monitor_ok+dut.engine.success_frame;monitor_total=monitor_total+dut.engine.success_frame;
        if(led[3] || dut.engine.failed_frame) $fatal(1,"Codec failed");
        if(PROGRESSIVE) begin
            if(pixel_stalled && (!dut.engine.codec.s_valid ||
                {dut.engine.codec.s_eof,dut.engine.codec.s_eol,dut.engine.codec.s_sof,dut.engine.codec.s_data}!==held_pixel))
                $fatal(1,"Raster changed under CDC backpressure");
            pixel_stalled=dut.engine.codec.s_valid && !dut.engine.codec.s_ready;
            held_pixel={dut.engine.codec.s_eof,dut.engine.codec.s_eol,dut.engine.codec.s_sof,dut.engine.codec.s_data};
            if(dut.engine.codec.s_valid && dut.engine.codec.s_ready) begin
                if(dut.engine.codec.s_sof) begin px=0;py=0;start_tick=tick;inflight=1;wait_in=0;wait_out=0;end
                expected_y=(3*px+2*py)&255;
                expected_c=px%2?(px/2+3*py+160)&255:(px+py+80)&255;
                if(dut.engine.codec.s_data!=={expected_c,expected_y} ||
                    dut.engine.codec.s_eol!==(px==dut.engine.width-1)) $fatal(1,"Raster pixel/line order");
                if(dut.engine.codec.s_eof) begin
                    feed_tick=tick-start_tick;
                    if(feed_tick-wait_in!=dut.engine.width*dut.engine.height-1) $fatal(1,"Pixel cadence");
                end
                if(px==dut.engine.width-1) begin px=0;py=py+1;end else px=px+1;
            end
            if(inflight) begin
                if(dut.engine.codec.s_valid && !dut.engine.codec.s_ready) wait_in=wait_in+1;
                if(dut.engine.m_valid && !dut.engine.m_ready) wait_out=wait_out+1;
            end
            if(dut.engine.word_taken) begin
                if(packet_word==0) begin descriptor=dut.engine.m_data[11:10]==1;
                    last_payload=dut.engine.m_data[11:10]==0 && dut.engine.m_data[6];end
                if(packet_word==1) packet_id=dut.engine.m_data;
                if(dut.engine.m_packet_last) begin
                    if(descriptor) begin
                        if(completed!=0) $fwrite(timing_trace,",\n");
                        $fwrite(timing_trace,"{\"frame_id\":%0d,\"feed_ticks\":%0d,\"jpeg_ticks\":%0d,\"total_ticks\":%0d,\"input_wait_ticks\":%0d,\"output_wait_ticks\":%0d}",
                            packet_id,feed_tick,jpeg_tick,tick-start_tick,wait_in,wait_out);
                        inflight=0;
                    end else if(last_payload) jpeg_tick=tick-start_tick;
                    packet_word=0;
                end else packet_word=packet_word+1;
            end
        end
        completed=completed+dut.engine.success_frame;tick=tick+1;
        #0.001;
        if(dut.engine.fps_sample_valid) begin
            monitor_windows=monitor_windows+1;
            if(monitor_ticks!=24000 || dut.engine.compressed_fps!=monitor_ok ||
                dut.engine.input_fps!=monitor_in || dut.engine.total_compressed!=monitor_total)
                $fatal(1,"Independent FPS accounting");
            $fwrite(rate_trace,"%0d,%0d,%0d,0,%0d\n",monitor_windows,monitor_in,monitor_ok,monitor_total);
            monitor_ticks=0;monitor_in=0;monitor_ok=0;
        end
    end
    task command(input [7:0] value);
        begin @(negedge usb_clk);commands[command_write]=value;command_write=command_write+1;
            wait(command_read==command_write);end
    endtask
    task quiet;
        begin wait(!dut.tx_valid && !dut.synchronous.tx_fifo.m_valid && !dut.synchronous.link.held_valid);
            repeat(500) @(negedge core_clk);end
    endtask
    task phase(input [7:0] value,input integer target);
        integer windows;
        begin
            command(value);wait(completed>=target-1);command(8'h53);
            wait(led[2] && !led[1]);windows=monitor_windows;
            wait(monitor_windows>=windows+3);quiet();
            if(completed!=target) $fatal(1,"Progressive stop must finish two full frames");
        end
    endtask
    initial begin
        capture=$fopen(PROGRESSIVE?"sync_progressive_capture.bin":"sync_small_capture.bin","wb");
        rate_trace=$fopen("fps_expected.csv","w");link_trace=$fopen("link_expected.csv","w");
        timing_trace=$fopen("timing_expected.json","w");
        $fwrite(rate_trace,"window,input_fps,compressed_fps,failed_fps,total_compressed\n");
        $fwrite(link_trace,"window,cycles,writes,write_busy_cycles,txe_wait_cycles,upstream_empty_cycles,rx_cycles\n");
        $fwrite(timing_trace,"[\n");
        #173;rst_n=1;wait(dut.core_clock_locked);repeat(20) @(negedge core_clk);
        if(PROGRESSIVE) begin phase(8'h56,2);phase(8'h48,4);phase(8'h46,6);end
        else begin
            command(8'h47);wait(led[2]);quiet();command(8'h47);wait(!led[2]);wait(led[2]);
            wait(monitor_windows>=3);quiet();
            if(completed!=18) $fatal(1,"Small frame count");
        end
        if(longest_burst<32 || blocked_bytes==0 || read_bytes!=command_write)
            $fatal(1,"Missing continuous writes/TXE/read coverage: burst=%0d blocked=%0d reads=%0d commands=%0d",longest_burst,blocked_bytes,read_bytes,command_write);
        if(checked_core_edges<24000) $fatal(1,"Missing MMCM frequency coverage");
        $fwrite(timing_trace,"\n]\n");
        $fclose(capture);$fclose(rate_trace);$fclose(link_trace);$fclose(timing_trace);
        marker=$fopen("SYNC_BOARD_PASS.txt","w");
        $fdisplay(marker,"%0d frames, %0d bytes, longest %0d-byte burst, %0d blocked edges, %0d commands; 9ns peer delay/setup/turnaround/counters passed",
            completed,bytes_seen,longest_burst,blocked_bytes,read_bytes);
        $fclose(marker);$finish;
    end
endmodule
