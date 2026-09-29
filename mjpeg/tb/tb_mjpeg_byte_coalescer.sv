`timescale 1ns/1ps
module tb_mjpeg_byte_coalescer;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,s_valid=0,s_first=0,s_last=0,m_ready=0,flush=0;
    reg [127:0] s_data=0;reg [4:0] s_bytes=0;reg [1:0] channel=0;reg [31:0] id=0;
    wire ready_a,ready_b;wire [127:0] data_a,data_b;
    wire [4:0] bytes_a,bytes_b;wire first_a,first_b,last_a,last_b,valid_a,valid_b,idle_a,idle_b;
    wire [1:0] channel_a,channel_b;wire [31:0] id_a,id_b;
    mjpeg_payload_coalescer original(.clk(clk),.rst_n(rst_n),.s_data(s_data),.s_bytes(s_bytes),
        .s_first(s_first),.s_last(s_last),.s_valid(s_valid),.s_ready(ready_a),.s_channel(channel),.s_frame_id(id),.flush(flush),
        .m_data(data_a),.m_bytes(bytes_a),.m_first(first_a),.m_last(last_a),.m_valid(valid_a),.m_ready(m_ready),
        .m_channel(channel_a),.m_frame_id(id_a),.idle(idle_a));
    mjpeg_byte_coalescer optimized(.clk(clk),.rst_n(rst_n),.s_data(s_data),.s_bytes(s_bytes),
        .s_first(s_first),.s_last(s_last),.s_valid(s_valid),.s_ready(ready_b),.s_channel(channel),.s_frame_id(id),.flush(flush),
        .m_data(data_b),.m_bytes(bytes_b),.m_first(first_b),.m_last(last_b),.m_valid(valid_b),.m_ready(m_ready),
        .m_channel(channel_b),.m_frame_id(id_b),.idle(idle_b));
    integer cycles=0,frames=0,length=0,pos=0;
    always @(posedge clk) if(rst_n) begin
        cycles<=cycles+1;
        if({ready_a,valid_a,idle_a}!={ready_b,valid_b,idle_b}) $fatal(1,"Flow control mismatch");
        if(valid_a && {bytes_a,first_a,last_a,channel_a,id_a}!={bytes_b,first_b,last_b,channel_b,id_b}) $fatal(1,"Metadata mismatch");
        if(valid_a && (data_a & (128'hffffffffffffffffffffffffffffffff>>((16-bytes_a)*8)))!==
            (data_b & (128'hffffffffffffffffffffffffffffffff>>((16-bytes_b)*8)))) $fatal(1,"Byte mismatch");
        if(cycles>500000) $fatal(1,"Timeout frame=%0d pos=%0d original_count=%0d",frames,pos,original.count);
    end
    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        for(frames=0;frames<2000;frames=frames+1) begin
            length=$urandom_range(0,90);pos=0;id=frames;channel=frames%4;
            while(pos<=length) begin
                @(negedge clk);m_ready=$urandom_range(0,3)!=0;flush=$urandom_range(0,20)==0;
                if(!s_valid) begin
                    s_valid=$urandom_range(0,3)!=0;
                    s_data=$urandom;s_first=pos==0;s_last=pos==length;
                    s_bytes=(pos==length && frames%5==0)?0:1;
                end
                @(posedge clk);
                if(s_valid && ready_a) begin
                    pos=pos+1;
                    @(negedge clk);s_valid=0;
                end
            end
        end
        @(negedge clk);s_valid=0;flush=1;m_ready=1;
        repeat(20) @(negedge clk);
        if(!idle_a || !idle_b) $fatal(1,"Final drain");
        $display("BYTE_COALESCER_PASS 2000 frames, random stalls/flush/abort, cycle-exact metadata and payload");
        $finish;
    end
endmodule
