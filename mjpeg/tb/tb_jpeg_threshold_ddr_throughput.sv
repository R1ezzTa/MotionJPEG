`timescale 1ns/1ps
module tb_jpeg_threshold_ddr_throughput;
    reg clk=0,rst_n=0,q_valid=0,feeding=0;
    always #5 clk=~clk;
    reg [6:0] q_addr=0;reg [7:0] q_value=0;reg [20:0] q_recip=0;
    reg [15:0] x=0,y=0;reg [31:0] frame=0;
    reg [28:0] quant[0:383];
    wire [15:0] pixel;wire q_ready,tables_ready,config_error,busy,s_ready,protocol_error,coefficient_error;
    wire [127:0] data,spatial_data;wire [4:0] bytes,spatial_bytes;
    wire valid,last,spatial_ready,spatial_valid,spatial_last,recovering,mem_fault,mem_active;
    wire cmd_valid,cmd_ready,cmd_write,w_valid,w_ready,w_last,r_valid,r_ready,r_last,mem_done,mem_error;
    wire [27:0] cmd_addr;wire [13:0] cmd_bytes;wire [127:0] w_data,r_data;wire [15:0] w_keep;
    wire [31:0] reads,writes,write_beats,read_beats,zero_keep_beats;
    reg [63:0] tick=0,start_tick=0,feed_ticks=0,last_ticks=0,input_wait=0;
    reg finished=0;integer i,j,capture=0,raw_capture=0,trace=0,marker=0;
    board_test_gradient source(.x(x),.y(y),.pixel(pixel));
    jpeg_encoder #(.MAX_WIDTH(1920),.RESTART_MCUS(4)) core(
        .clk(clk),.rst_n(rst_n),.cfg_width(16'd1920),.cfg_height(16'd1080),.cfg_gray(1'b0),
        .cfg_q_valid(q_valid),.cfg_q_ready(q_ready),.cfg_q_addr(q_addr),.cfg_q_value(q_value),.cfg_q_recip(q_recip),
        .tables_ready(tables_ready),.config_error(config_error),.busy(busy),
        .s_data(pixel),.s_valid(feeding),.s_ready(s_ready),.s_sof(x==0 && y==0),.s_eol(x==1919),.s_eof(x==1919 && y==1079),
        .m_data(data),.m_bytes(bytes),.m_valid(valid),.m_ready(spatial_ready),.m_last(last),
        .protocol_error(protocol_error),.coefficient_error(coefficient_error));
    jpeg_spatial_skip_ddr skip(
        .clk(clk),.rst_n(rst_n),.invalidate(q_valid && q_ready),.abort(1'b0),.recovering(recovering),.mem_fault(mem_fault),.mem_active(mem_active),
        .frame_id(frame),.width(16'd1920),.height(16'd1080),.gray(1'b0),
        .cfg_threshold(8'd128),.cfg_q_valid(q_valid && q_ready),.cfg_q_addr(q_addr),.cfg_q_value(q_value),
        .s_data(data),.s_bytes(bytes),.s_last(last),.s_valid(valid),.s_ready(spatial_ready),
        .m_data(spatial_data),.m_bytes(spatial_bytes),.m_last(spatial_last),.m_valid(spatial_valid),.m_ready(1'b1),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_bytes(cmd_bytes),
        .w_data(w_data),.w_keep(w_keep),.w_valid(w_valid),.w_ready(w_ready),.w_last(w_last),
        .r_data(r_data),.r_valid(r_valid),.r_ready(r_ready),.r_last(r_last),.mem_done(mem_done),.mem_error(mem_error));
    spatial_ddr_memory_model #(.RANDOM_STALLS(0)) ram(
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_bytes(cmd_bytes),
        .w_data(w_data),.w_keep(w_keep),.w_valid(w_valid),.w_ready(w_ready),.w_last(w_last),
        .r_data(r_data),.r_valid(r_valid),.r_ready(r_ready),.r_last(r_last),.done(mem_done),.error(mem_error),.busy(),
        .reads(reads),.writes(writes),.write_beats(write_beats),.read_beats(read_beats),.zero_keep_beats(zero_keep_beats));
    always @(posedge clk) if(rst_n) begin
        if(tick>100000000) $fatal(1,"DDR FHD watchdog frame=%0d state=%0d",frame,skip.state);
        if(config_error || protocol_error || coefficient_error || mem_fault) $fatal(1,"DDR FHD codec/memory fault");
        if(feeding && s_ready) begin
            if(x==0 && y==0) begin start_tick=tick;input_wait=0;end
            if(x==1919 && y==1079) begin feeding<=0;feed_ticks=tick-start_tick;end
            else if(x==1919) begin x<=0;y<=y+1'b1;end
            else x<=x+1'b1;
        end
        if(feeding && !s_ready) input_wait=input_wait+1;
        if(valid && spatial_ready) for(j=0;j<bytes;j=j+1) $fwrite(raw_capture,"%c",data[j*8+:8]);
        if(spatial_valid) begin
            for(j=0;j<spatial_bytes;j=j+1) $fwrite(capture,"%c",spatial_data[j*8+:8]);
            if(spatial_last) begin last_ticks=tick-start_tick;finished<=1;end
        end
        tick=tick+1;
    end
    initial begin
        $readmemh("data/board_test/quant.mem",quant);
        trace=$fopen("ddr_throughput.json","w");$fwrite(trace,"[\n");
        repeat(5) @(negedge clk);rst_n=1;
        for(i=0;i<128;i=i+1) begin
            @(negedge clk);q_addr=i;q_value=quant[i][7:0];q_recip=quant[i][28:8];q_valid=1;
            @(posedge clk);while(!q_ready) @(posedge clk);@(negedge clk);q_valid=0;
        end
        wait(tables_ready);
        for(frame=0;frame<2;frame=frame+1) begin
            capture=$fopen($sformatf("ddr_fhd_%0d.spj",frame),"wb");raw_capture=$fopen($sformatf("ddr_fhd_%0d.jpg",frame),"wb");
            @(negedge clk);x=0;y=0;feeding=1;finished=0;
            wait(!feeding);wait(finished);wait(!busy && !mem_active && skip.state==0);@(negedge clk);
            if(feed_ticks-input_wait!=1920*1080-1) $fatal(1,"FHD input coverage");
            if(frame!=0) $fwrite(trace,",\n");
            $fwrite(trace,"{\"frame_id\":%0d,\"feed_ticks\":%0d,\"output_ticks\":%0d,\"total_ticks\":%0d,\"input_wait_ticks\":%0d,\"memory_reads_total\":%0d,\"memory_writes_total\":%0d}",frame,feed_ticks,last_ticks,tick-start_tick,input_wait,reads,writes);
            $display("DDR_FHD frame %0d ticks=%0d ideal_fps=%f reads=%0d writes=%0d",frame,tick-start_tick,100000000.0/(tick-start_tick),reads,writes);
            $fclose(capture);$fclose(raw_capture);
        end
        if(reads!=4050 || writes!=4050) $fatal(1,"Full-position DDR coverage reads=%0d writes=%0d",reads,writes);
        $fwrite(trace,"\n]\n");$fclose(trace);
        marker=$fopen("JPEG_THRESHOLD_DDR_THROUGHPUT_PASS.txt","w");
        $fdisplay(marker,"Two FHD frames, all4050 positions cached/reused with threshold128, no input dropped; throughput recorded separately");
        $fclose(marker);$finish;
    end
endmodule
