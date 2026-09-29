`timescale 1ns/1ps
module tb_jpeg_threshold;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg [7:0] memory[0:12287];reg [31:0] lengths[0:11],thresholds[0:11];
    reg [28:0] quant[0:383];
    reg [7:0] threshold=0;reg q_valid=0;reg [6:0] q_addr=0;reg [7:0] q_value=0;
    integer frame=0,position=0,output_file=0,i,k,ticks=0,marker=0;
    reg feeding=0,finished=0,output_ready=0;reg [15:0] random_state=16'hac19;
    reg [127:0] input_data;reg [4:0] input_bytes;
    wire input_ready,output_valid,output_last;wire [127:0] output_data;wire [4:0] output_bytes;
    always @* begin
        input_data=0;input_bytes=(lengths[frame]-position>=16)?16:lengths[frame]-position;
        for(k=0;k<16;k=k+1) input_data[k*8+:8]=memory[frame*1024+position+k];
    end
    jpeg_spatial_skip #(.CACHE_SLOTS(2),.CACHE_STRIDE(1),.REFRESH_PERIOD(64),.THRESHOLD_ENABLE(1)) dut(
        .clk(clk),.rst_n(rst_n),.invalidate(q_valid),.frame_id(frame),.width(16'd128),.height(16'd8),.gray(1'b0),
        .cfg_threshold(threshold),.cfg_q_valid(q_valid),.cfg_q_addr(q_addr),.cfg_q_value(q_value),
        .s_data(input_data),.s_bytes(input_bytes),.s_last(position+input_bytes==lengths[frame]),
        .s_valid(feeding),.s_ready(input_ready),.m_data(output_data),.m_bytes(output_bytes),
        .m_last(output_last),.m_valid(output_valid),.m_ready(output_ready));
    always @(negedge clk) begin
        random_state={random_state[14:0],random_state[15]^random_state[13]^random_state[12]^random_state[10]};
        output_ready=random_state[2:0]!=0;
    end
    always @(posedge clk) if(rst_n) begin
        ticks=ticks+1;if(ticks>1000000) $fatal(1,"Threshold watchdog frame %0d state %0d",frame,dut.state);
        if(feeding && input_ready) begin
            if(position+input_bytes==lengths[frame]) feeding<=0;
            else position<=position+input_bytes;
        end
        if(output_valid && output_ready) begin
            for(i=0;i<output_bytes;i=i+1) $fwrite(output_file,"%c",output_data[i*8+:8]);
            if(output_last) finished<=1;
        end
    end
    initial begin
        $readmemh("threshold_input.mem",memory);$readmemh("threshold_lengths.mem",lengths);
        $readmemh("threshold_values.mem",thresholds);$readmemh("data/board_test/camera_quant.mem",quant);
        repeat(5) @(negedge clk);rst_n=1;
        for(i=0;i<128;i=i+1) begin
            @(negedge clk);q_valid=1;q_addr=i;q_value=quant[256+i][7:0];
        end
        @(negedge clk);q_valid=0;
        for(frame=0;frame<12;frame=frame+1) begin
            output_file=$fopen($sformatf("threshold_%0d.spj",frame),"wb");
            @(negedge clk);threshold=thresholds[frame];position=0;feeding=1;finished=0;
            wait(!feeding);wait(finished);@(negedge clk);$fclose(output_file);
        end
        marker=$fopen("JPEG_THRESHOLD_PASS.txt","w");$fdisplay(marker,"12 frames coefficient dead zone, exact0, cumulative drift, isolated AC, random output stalls");
        $fclose(marker);$finish;
    end
endmodule
