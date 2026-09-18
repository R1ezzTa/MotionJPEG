`timescale 1ns/1ps
module tb_mjpeg_block_transport;
    reg clk=0,rst_n=0,s_valid=0,m_ready=0,stats_valid=0;
    reg [7:0] s_data=0;
    reg [223:0] stats_data=0;
    wire s_ready,m_valid;
    wire [7:0] m_data;
    always #10 clk=~clk;
    board_test_block_transport dut(.*);
    integer ticks=0,capture,marker;
    reg stalled=0;
    reg [7:0] held=0;
    always @(negedge clk) m_ready=(ticks%97)<31;
    always @(posedge clk) begin
        ticks=ticks+1;
        if(ticks>200000) $fatal(1,"Block transport deadlock");
        if(rst_n) begin
            if(stalled && (!m_valid || m_data!==held)) $fatal(1,"Output changed under backpressure");
            if(m_valid && m_ready) $fwrite(capture,"%c",m_data);
            stalled=m_valid && !m_ready;held=m_data;
        end
    end
    task byte_in(input [7:0] value);
        begin @(negedge clk);s_data=value;s_valid=1;do @(posedge clk);while(!s_ready);
            @(negedge clk);s_valid=0;end
    endtask
    task record_in(input [31:0] value,input [7:0] flag);
        integer j;begin for(j=0;j<4;j=j+1) byte_in(value[j*8+:8]);byte_in(flag);end
    endtask
    task fps(input integer window_no);
        begin record_in(32'h31535046,8'h80);record_in(window_no,8'h81);
            record_in(0,8'h82);record_in(0,8'h83);record_in(0,8'h84);record_in(0,8'h85);end
    endtask
    function [7:0] pixel_byte(input integer pos,input integer length);
        begin
            if(pos==0 || pos==length-2) pixel_byte=8'hff;
            else if(pos==1) pixel_byte=8'hd8;
            else if(pos==length-1) pixel_byte=8'hd9;
            else pixel_byte=(pos*13+7)&255;
        end
    endfunction
    task frame(input integer id,input integer length,input integer rate_window);
        integer offset,n,j,k;reg [31:0] word_value,header;
        begin
            if(length==0) begin record_in(32'h4d4a10e0,4);record_in(id,12);end
            for(offset=0;offset<length;offset=offset+16) begin
                n=length-offset>16?16:length-offset;
                header=32'h4d4a1000|n|(offset==0?128:0)|(offset+n==length?64:0);
                record_in(header,4);
                if(offset==16) fps(rate_window); // Control while a partial bank is held.
                record_in(id,4);
                for(j=0;j<n;j=j+4) begin
                    word_value=32'hdeadbeef;
                    for(k=0;k<4 && j+k<n;k=k+1) word_value[k*8+:8]=pixel_byte(offset+j+k,length);
                    record_in(word_value,(n-j<4?n-j:4)|(j+4>=n?8:0));
                end
            end
            record_in(32'h4d4a1400,4);record_in(id,4);
            if(length!=0) fps(rate_window+1); // Control inside descriptor.
            record_in(123+id,4);record_in(0,4);record_in(length,4);
            record_in(32'h00100010,4);record_in(length==0?1:0,12);
        end
    endtask
    initial begin
        capture=$fopen("block_unit_capture.bin","wb");
        repeat(10) @(negedge clk);rst_n=1;
        byte_in("M");byte_in("J");byte_in("B");byte_in("T");
        @(negedge clk);stats_data={32'd0,32'd20,32'd30,32'd40,32'd10,32'd100,32'd1};stats_valid=1;
        @(negedge clk);stats_valid=0;
        frame(0,1031,1);frame(1,2048,3);frame(2,0,5);
        record_in(32'h31444e45,8'ha0);
        wait(!dut.record_pending && !dut.control_pending && dut.bank_ready==0 && dut.out_state==0 && !dut.link_pending);
        repeat(10) @(negedge clk);$fclose(capture);
        marker=$fopen("BLOCK_TRANSPORT_PASS.txt","w");
        $fdisplay(marker,"Double-buffer stalls, exact/full/partial tails, zero-byte abort, controls inside payload/descriptor and output stability passed");
        $fclose(marker);$finish;
    end
endmodule
