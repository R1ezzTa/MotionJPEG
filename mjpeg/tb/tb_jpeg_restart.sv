`timescale 1ns/1ps
module tb_jpeg_restart;
    reg clk=0,rst_n=0,q_valid=0,feeding=0;
    always #5 clk=~clk;
    reg [6:0] q_addr=0;reg [7:0] q_value=0;reg [20:0] q_recip=0;
    reg [15:0] x=0,y=0;
    integer frame=0,output_file=0,spatial_file=0,marker=0,i,j,ticks=0;
    reg spatial_done=0;
    reg [28:0] quant[0:383];
    wire [15:0] gradient;wire [15:0] pixel={gradient[15:8],
        (frame==2 && x<64 && y<8)?(gradient[7:0]+8'd17):gradient[7:0]};
    wire q_ready,tables_ready,config_error,busy,s_ready,valid,last,protocol_error,coefficient_error;
    wire [127:0] data;wire [4:0] bytes;
    reg ready=0;reg [15:0] random_state=16'h5429;
    wire spatial_ready,spatial_valid,spatial_last;
    wire [127:0] spatial_data;wire [4:0] spatial_bytes;
    wire spatial_output_ready=random_state[5:3]!=0;
    jpeg_spatial_skip #(.CACHE_SLOTS(3),.CACHE_STRIDE(2)) skip(
        .clk(clk),.rst_n(rst_n),.invalidate(q_valid && q_ready),.frame_id(frame),
        .width(16'd128),.height(16'd24),.gray(1'b0),
        .s_data(data),.s_bytes(bytes),.s_last(last),.s_valid(valid && ready),.s_ready(spatial_ready),
        .m_data(spatial_data),.m_bytes(spatial_bytes),.m_last(spatial_last),
        .m_valid(spatial_valid),.m_ready(spatial_output_ready));
    board_test_gradient source(.x(x),.y(y),.pixel(gradient));
    jpeg_encoder #(.MAX_WIDTH(128),.RESTART_MCUS(4)) dut(
        .clk(clk),.rst_n(rst_n),.cfg_width(16'd128),.cfg_height(16'd24),.cfg_gray(1'b0),
        .cfg_q_valid(q_valid),.cfg_q_ready(q_ready),.cfg_q_addr(q_addr),.cfg_q_value(q_value),
        .cfg_q_recip(q_recip),.tables_ready(tables_ready),.config_error(config_error),
        .s_data(pixel),.s_valid(feeding),.s_ready(s_ready),.s_sof(x==0 && y==0),
        .s_eol(x==127),.s_eof(x==127 && y==23),.m_data(data),.m_bytes(bytes),
        .m_valid(valid),.m_ready(ready && spatial_ready),.m_last(last),.busy(busy),
        .protocol_error(protocol_error),.coefficient_error(coefficient_error));
    always @(negedge clk) begin
        random_state={random_state[14:0],random_state[15]^random_state[13]^random_state[12]^random_state[10]};
        ready=random_state[2:0]!=0;
    end
    always @(posedge clk) if(rst_n) begin
        ticks=ticks+1;if(ticks>1000000) $fatal(1,"Restart watchdog");
        if(config_error || protocol_error || coefficient_error) $fatal(1,"Restart codec error");
        if(feeding && s_ready) begin
            if(x==127 && y==23) feeding<=0;
            else if(x==127) begin x<=0;y<=y+1'b1;end
            else x<=x+1'b1;
        end
        if(valid && ready && spatial_ready) for(j=0;j<bytes;j=j+1) $fwrite(output_file,"%c",data[j*8+:8]);
        if(spatial_valid && spatial_output_ready) begin
            for(j=0;j<spatial_bytes;j=j+1) $fwrite(spatial_file,"%c",spatial_data[j*8+:8]);
            if(spatial_last) spatial_done<=1;
        end
    end
    task load_quality(input integer bank);
        begin for(i=0;i<128;i=i+1) begin
            @(negedge clk);q_addr=i;q_value=quant[bank*128+i][7:0];
            q_recip=quant[bank*128+i][28:8];q_valid=1;
            @(posedge clk);while(!q_ready) @(posedge clk);
            @(negedge clk);q_valid=0;
        end wait(tables_ready);end
    endtask
    initial begin
        $readmemh("data/board_test/camera_quant.mem",quant);
        repeat(5) @(negedge clk);rst_n=1;load_quality(2);
        for(frame=0;frame<4;frame=frame+1) begin
            if(frame==3) load_quality(0);
            output_file=$fopen($sformatf("restart_%0d.jpg",frame),"wb");
            spatial_file=$fopen($sformatf("spatial_%0d.spj",frame),"wb");
            @(negedge clk);x=0;y=0;feeding=1;spatial_done=0;
            wait(!feeding);wait(!busy);wait(spatial_done);@(negedge clk);
            $fclose(output_file);$fclose(spatial_file);
        end
        marker=$fopen("JPEG_RESTART_PASS.txt","w");$fdisplay(marker,"4 restart JPEGs, random stalls, local change, quality change");
        $fclose(marker);$finish;
    end
endmodule
