`timescale 1ns/1ps
// Full-HD core measurement: continuous input and always-ready raw JPEG output.
// Capture two actual JPEGs; no USB framing or timing inference from host clocks.
module tb_mjpeg_threshold_throughput;
    reg clk=0,rst_n=0,q_valid=0,feeding=0;
    always #5 clk=~clk;
    reg [6:0] q_addr=0;
    reg [7:0] q_value=0;
    reg [20:0] q_recip=0;
    wire q_ready,tables_ready,config_error,busy,s_ready;
    reg [15:0] x=0,y=0;
    wire [15:0] pixel;
    wire [127:0] data;
    wire [4:0] bytes;
    wire first,last,valid,desc_valid,desc_gray;
    wire [1:0] channel,desc_channel;
    wire [31:0] id,desc_id,desc_length;
    wire [63:0] desc_timestamp;
    wire [15:0] desc_width,desc_height;
    wire [7:0] desc_status;
    reg [28:0] quant[0:383];
    reg [63:0] tick=0,start_tick=0;
    reg [63:0] feed_ticks=0,jpeg_ticks=0,input_wait=0;
    reg measured=0;
    integer capture=0,trace=0,marker=0,completed=0,byte_count=0,i,j;
    board_test_gradient generator(.x(x),.y(y),.pixel(pixel));
    mjpeg_encoder #(.CHANNELS(1),.MAX_WIDTH(1920),.RESTART_MCUS(4),.SPATIAL_SKIP(1),.SPATIAL_THRESHOLD(1)) dut(
        .clk(clk),.rst_n(rst_n),.enable(1'b1),.cfg_gray(1'b0),
        .cfg_skip_threshold(8'd128),.cfg_width(16'd1920),.cfg_height(16'd1080),.cfg_q_valid(q_valid),.cfg_q_ready(q_ready),
        .cfg_q_addr(q_addr),.cfg_q_value(q_value),.cfg_q_recip(q_recip),
        .tables_ready(tables_ready),.config_error(config_error),.busy(busy),
        .s_data(pixel),.s_valid(feeding),.s_ready(s_ready),.s_sof(x==0 && y==0),
        .s_eol(x==1919),.s_eof(x==1919 && y==1079),.s_abort(1'b0),.s_timestamp(tick),
        .m_data(data),.m_bytes(bytes),.m_first(first),.m_last(last),.m_valid(valid),.m_ready(1'b1),
        .m_channel(channel),.m_frame_id(id),.desc_valid(desc_valid),.desc_ready(1'b1),
        .desc_channel(desc_channel),.desc_frame_id(desc_id),.desc_length(desc_length),
        .desc_timestamp(desc_timestamp),.desc_width(desc_width),.desc_height(desc_height),
        .desc_gray(desc_gray),.desc_status(desc_status));
    always @(posedge clk) if(rst_n) begin
        if(tick>100000000) $fatal(1,"Core throughput watchdog");
        if(config_error) $fatal(1,"Core configuration error");
        if(feeding && s_ready) begin
            if(x==0 && y==0) begin start_tick=tick;input_wait=0;byte_count=0;measured=1; end
            if(x==1919 && y==1079) begin feeding<=0;feed_ticks=tick-start_tick; end
            else if(x==1919) begin x<=0;y<=y+1'b1; end
            else x<=x+1'b1;
        end
        if(measured && feeding && !s_ready) input_wait=input_wait+1;
        if(valid) begin
            if(channel!=0 || id!=completed || bytes==0 || bytes>16) $fatal(1,"Raw JPEG metadata");
            if(first!==(byte_count==0)) $fatal(1,"Raw JPEG first marker");
            for(j=0;j<bytes;j=j+1) $fwrite(capture,"%c",data[j*8+:8]);
            byte_count=byte_count+bytes;
            if(last) jpeg_ticks=tick-start_tick;
        end
        if(desc_valid) begin
            if(desc_id!=completed || desc_length!=byte_count || desc_status!=0 ||
               desc_width!=1920 || desc_height!=1080 || desc_gray) $fatal(1,"Core descriptor");
            if(feed_ticks-input_wait!=1920*1080-1) $fatal(1,"Full-HD input coverage");
            if(completed!=0) $fwrite(trace,",\n");
            $fwrite(trace,"{\"frame_id\":%0d,\"feed_ticks\":%0d,\"jpeg_ticks\":%0d,\"total_ticks\":%0d,\"input_wait_ticks\":%0d,\"jpeg_bytes\":%0d}",
                completed,feed_ticks,jpeg_ticks,tick-start_tick,input_wait,byte_count);
            $fclose(capture);capture=0;measured=0;completed=completed+1;
        end
        tick=tick+1;
    end
    initial begin
        $readmemh("data/board_test/quant.mem",quant);
        trace=$fopen("core_timings.json","w");$fwrite(trace,"[\n");
        repeat(5) @(negedge clk);rst_n=1;
        for(i=0;i<128;i=i+1) begin
            @(negedge clk);q_addr=i;q_value=quant[i][7:0];q_recip=quant[i][28:8];q_valid=1;
            @(posedge clk);while(!q_ready) @(posedge clk);
            @(negedge clk);q_valid=0;
        end
        wait(tables_ready);
        capture=$fopen("core_fhd_0.jpg","wb");@(negedge clk);x=0;y=0;feeding=1;
        wait(completed==1);wait(!busy);
        capture=$fopen("core_fhd_1.jpg","wb");@(negedge clk);x=0;y=0;feeding=1;
        wait(completed==2);@(negedge clk);
        $fwrite(trace,"\n]\n");$fclose(trace);
        marker=$fopen("CORE_THROUGHPUT_SIM_PASS.txt","w");
        $fdisplay(marker,"Two complete 1920x1080 raw JPEG frames; continuous pixels, always-ready output, descriptor and coverage checks passed");
        $fclose(marker);$finish;
    end
endmodule
