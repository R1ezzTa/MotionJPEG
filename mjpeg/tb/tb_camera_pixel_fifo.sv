`timescale 1ns/1ps
module tb_camera_pixel_fifo;
    reg wclk=0,rclk=0,write_clock_run=1,read_clock_run=1,reset_n=0,flush=0;
    always #20 if(write_clock_run) wclk=~wclk;else wclk=0;
    always #5 if(read_clock_run) rclk=~rclk;else rclk=0;
    reg [7:0] source=0;
    reg send=0,receive=0;
    wire ready,valid,wcommon_reset_n,rflush_active,queue_pressure;
    wire [7:0] front;
    integer i,marker;
    camera_pixel_fifo #(.WIDTH(8),.ADDRESS_BITS(4)) dut(
        .wclk(wclk),.rclk(rclk),.reset_n(reset_n),.flush(flush),
        .wcommon_reset_n(wcommon_reset_n),.rflush_active(rflush_active),
        .s_data(source),.s_valid(send),.s_ready(ready),.m_data(front),.m_valid(valid),.m_ready(receive),.queue_pressure(queue_pressure));
    task write_word(input [7:0] value);
        begin
            @(negedge wclk);source=value;send=1;
            do @(posedge wclk);while(!ready);
            @(negedge wclk);send=0;
        end
    endtask
    task read_word(input [7:0] expected);
        begin
            wait(valid);@(negedge rclk);
            if(front!==expected) $fatal(1,"FIFO stale/lost/order data=%h expected=%h",front,expected);
            receive=1;@(negedge rclk);receive=0;
        end
    endtask
    initial begin
        #33;reset_n=1;repeat(5) @(negedge wclk);
        for(i=0;i<6;i=i+1) write_word(8'h40+i);
        repeat(4) @(negedge rclk);if(!queue_pressure) $fatal(1,"FIFO quarter-full pressure did not assert");
        for(i=0;i<3;i=i+1) read_word(8'h40+i);
        repeat(4) @(negedge rclk);if(queue_pressure) $fatal(1,"FIFO pressure did not release below quarter full");
        for(i=3;i<6;i=i+1) read_word(8'h40+i);
        write_word(8'h31);write_word(8'h32);wait(valid);
        repeat(10) begin @(negedge rclk);if(!valid || front!==8'h31) $fatal(1,"Held front changed");end
        // Flush while the reader has no clock: async preset must invalidate
        // the front immediately and remain asserted until its clock resumes.
        read_clock_run=0;#17;flush=1;#1;
        if(valid || ready || queue_pressure || !rflush_active || !wcommon_reset_n)
            $fatal(1,"Flush assertion/common-reset isolation failed");
        repeat(4) @(negedge wclk);flush=0;
        repeat(5) @(negedge wclk);
        if(valid || dut.rflush_pipe!==3'b111) $fatal(1,"Reader flush released without clock");
        write_word(8'ha0);write_word(8'ha1);read_clock_run=1;
        read_word(8'ha0);read_word(8'ha1);
        // Global reset overlaps an asserted flush; flush disappears while
        // both clocks are absent. Reset pipes must mask their initial state.
        write_word(8'h55);write_clock_run=0;read_clock_run=0;#13;
        flush=1;#1;reset_n=0;#21;flush=0;#21;reset_n=1;#21;
        if(valid || ready || wcommon_reset_n) $fatal(1,"No-clock reset/flush overlap released queue");
        write_clock_run=1;read_clock_run=1;repeat(6) @(negedge wclk);
        if(valid) $fatal(1,"Overlap left a stale front");
        for(i=0;i<40;i=i+1) begin write_word(8'h70+i);read_word(8'h70+i);end
        repeat(5) @(negedge rclk);if(valid) $fatal(1,"FIFO did not drain");
        marker=$fopen("CAMERA_PIXEL_FIFO_PASS.txt","w");
        $fdisplay(marker,"Separate common-reset/flush synchronizers: held front, immediate async flush, paused reader clock, reset+flush overlap with both clocks absent, fresh-word recovery and pointer wrap passed");
        $fclose(marker);$finish;
    end
    initial begin #1000000;$fatal(1,"FIFO timeout");end
endmodule
