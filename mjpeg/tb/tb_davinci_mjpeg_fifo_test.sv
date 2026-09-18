`timescale 1ns/1ps
// FT232H behavioral peer, including FIFO backpressure and bus turnaround.
module tb_davinci_mjpeg_fifo_test;
    reg clk=0,rst_n=0,rx_pending=0,txe_n=0;
    always #10 clk=~clk;
    wire [7:0] data;
    wire rd_n,wr_n,oe_n,siwu_n;
    wire [3:0] led;
    wire [5:0] seg_sel;
    wire [7:0] seg_led;
    assign data=(!rd_n && rx_pending) ? 8'h47 : 8'bz;
    // Shorten one-second windows only for simulation. Hardware remains 50MHz.
    davinci_mjpeg_board_test_top #(.CLOCK_HZ(1000000)) dut(
        .sys_clk(clk),.sys_rst_n(rst_n),.usb_data(data),.usb_rxf_n(!rx_pending),.usb_txe_n(txe_n),
        .usb_rd_n(rd_n),.usb_wr_n(wr_n),.usb_oe_n(oe_n),.usb_siwu_n(siwu_n),.led(led),
        .seg_sel(seg_sel),.seg_led(seg_led));
    integer capture,bytes_seen=0,cycles=0,marker;
    time data_changed=0,wr_low=0,wr_high=0,rd_low=0;
    integer monitor_ticks=0,monitor_in=0,monitor_ok=0,monitor_bad=0,monitor_total=0,monitor_windows=0,rate_trace;
    initial rate_trace=$fopen("fps_expected.csv","w");
    initial #1 $fwrite(rate_trace,"window,input_fps,compressed_fps,failed_fps,total_compressed\n");
    always @(posedge clk) if(dut.engine.rst_n) begin
        monitor_ticks=monitor_ticks+1;
        monitor_in=monitor_in+dut.engine.input_frame;monitor_ok=monitor_ok+dut.engine.success_frame;
        monitor_bad=monitor_bad+dut.engine.failed_frame;monitor_total=monitor_total+dut.engine.success_frame;
        #1;
        if(dut.engine.fps_sample_valid) begin
            monitor_windows=monitor_windows+1;
            if(monitor_ticks!=1000000 || dut.engine.compressed_fps!=monitor_ok ||
               dut.engine.input_fps!=monitor_in || dut.engine.failed_fps!=monitor_bad ||
               dut.engine.total_compressed!=monitor_total) $fatal(1,"Integrated FPS counters differ from events");
            $fwrite(rate_trace,"%0d,%0d,%0d,%0d,%0d\n",monitor_windows,monitor_in,monitor_ok,monitor_bad,monitor_total);
            monitor_ticks=0;monitor_in=0;monitor_ok=0;monitor_bad=0;
        end
        if(dut.display.bcd_value!=0 && !$onehot0(~seg_sel)) $fatal(1,"Display digit collision");
    end
    always @(data) begin
        if(rst_n && wr_low!=0 && $time-wr_low<5) $fatal(1,"FIFO data hold");
        data_changed=$time;
    end
    always @(negedge rd_n) begin
        rd_low=$time;
        if (!wr_n || !rx_pending) $fatal(1,"Invalid FIFO read");
    end
    always @(posedge rd_n) if (rst_n && rx_pending) begin
        if ($time-rd_low<30) $fatal(1,"RD pulse too short");
        rx_pending=0;
    end
    always @(posedge wr_n) if (rst_n && wr_low!=0) begin
        if($time-wr_low<30) $fatal(1,"WR pulse too short");
        wr_high=$time;
    end
    always @(negedge wr_n) begin
        wr_low=$time;
        if(wr_high!=0 && $time-wr_high<49) $fatal(1,"FIFO write recovery");
        if (!rd_n || txe_n || $isunknown(data)) $fatal(1,"Invalid FIFO write/bus collision");
        if ($time-data_changed<5) $fatal(1,"FIFO data setup");
        $fwrite(capture,"%c",data); bytes_seen=bytes_seen+1;
        txe_n=1;
        #((bytes_seen%127==0)?40000:70); txe_n=0;
    end
    always @(posedge clk) begin
        cycles=cycles+1;
        if (cycles>12000000) $fatal(1,"FIFO test watchdog");
        if (led[3]) $fatal(1,"Codec error");
    end
    task trigger;
        begin @(negedge clk); rx_pending=1; wait(!rd_n); wait(rd_n); end
    endtask
    initial begin
        capture=$fopen("usb_capture.bin","wb");
        repeat(10) @(negedge clk); rst_n=1; repeat(10) @(negedge clk);
        trigger(); wait(led[2]); repeat(20) @(negedge clk);
        trigger(); wait(!led[2]); wait(led[2]); repeat(20) @(negedge clk);
        wait(monitor_windows>=1);
        repeat(10000) @(negedge clk);
        if(monitor_total!=18 || monitor_windows<1) $fatal(1,"FPS should count 18 complete frames, not payload packets");
        $fclose(capture);$fclose(rate_trace);
        marker=$fopen("SIM_PASS.txt","w");
        $fdisplay(marker,"FT245 async FIFO capture: 18 frames, %0d bytes, backpressure/setup/pulse/turnaround checks passed",bytes_seen);
        $fclose(marker);$finish;
    end
endmodule
