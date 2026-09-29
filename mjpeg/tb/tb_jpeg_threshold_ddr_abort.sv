`timescale 1ns/1ps
module tb_jpeg_threshold_ddr_abort #(parameter ADAPTIVE_TEST=0);
    reg clk=0,rst_n=0,abort=0,invalidate=0,hold_cmd=0,hold_write=0,fake_error=0;
    always #5 clk=~clk;
    reg [7:0] memory[0:12287];reg [31:0] lengths[0:11];reg [28:0] quant[0:383];
    reg q_valid=0;reg [6:0] q_addr=0;reg [7:0] q_value=0;
    integer frame=0,position=0,output_file=0,i,k,ticks=0,marker=0;
    reg feeding=0,finished=0;reg [127:0] input_data;reg [4:0] input_bytes;
    wire input_ready,output_valid,output_last,recovering,mem_fault,mem_active;
    wire [127:0] output_data;wire [4:0] output_bytes;
    wire cmd_valid,cmd_ready,model_cmd_ready,cmd_write,w_valid,w_ready,model_w_ready,w_last,r_valid,r_ready,r_last,mem_done,model_error;
    wire [27:0] cmd_addr;wire [13:0] cmd_bytes;wire [127:0] w_data,r_data;wire [15:0] w_keep;
    wire [31:0] reads,writes,write_beats,read_beats,zero_keep_beats;
    assign cmd_ready=model_cmd_ready && !hold_cmd;
    assign w_ready=model_w_ready && !hold_write;
    always @* begin
        input_data=0;input_bytes=(lengths[1]-position>=16)?16:lengths[1]-position;
        for(k=0;k<16;k=k+1) input_data[k*8+:8]=memory[1024+position+k];
    end
    jpeg_spatial_skip_ddr #(.REFRESH_PERIOD(64),.ADAPTIVE_ENABLE(ADAPTIVE_TEST)) dut(
        .clk(clk),.rst_n(rst_n),.invalidate(invalidate || q_valid),.abort(abort),.recovering(recovering),.mem_fault(mem_fault),.mem_active(mem_active),
        .frame_id(frame),.width(16'd128),.height(16'd8),.gray(1'b0),
        .cfg_threshold(8'd32),.cfg_adaptive(ADAPTIVE_TEST!=0),.input_pressure(1'b0),.cfg_q_valid(q_valid),.cfg_q_addr(q_addr),.cfg_q_value(q_value),
        .s_data(input_data),.s_bytes(input_bytes),.s_last(position+input_bytes==lengths[1]),
        .s_valid(feeding),.s_ready(input_ready),.m_data(output_data),.m_bytes(output_bytes),
        .m_last(output_last),.m_valid(output_valid),.m_ready(1'b1),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_bytes(cmd_bytes),
        .w_data(w_data),.w_keep(w_keep),.w_valid(w_valid),.w_ready(w_ready),.w_last(w_last),
        .r_data(r_data),.r_valid(r_valid),.r_ready(r_ready),.r_last(r_last),.mem_done(mem_done),.mem_error(model_error || fake_error));
    spatial_ddr_memory_model #(.SLOTS(2)) ram(
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid && !hold_cmd),.cmd_ready(model_cmd_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_bytes(cmd_bytes),
        .w_data(w_data),.w_keep(w_keep),.w_valid(w_valid && !hold_write),.w_ready(model_w_ready),.w_last(w_last),
        .r_data(r_data),.r_valid(r_valid),.r_ready(r_ready),.r_last(r_last),.done(mem_done),.error(model_error),.busy(),
        .reads(reads),.writes(writes),.write_beats(write_beats),.read_beats(read_beats),.zero_keep_beats(zero_keep_beats));
    always @(posedge clk) if(rst_n) begin
        ticks=ticks+1;if(ticks>1000000) $fatal(1,"DDR abort watchdog state=%0d active=%0d",dut.state,mem_active);
        if(recovering && input_ready) $fatal(1,"DDR recovering admitted input");
        if(feeding && input_ready) begin
            if(position+input_bytes==lengths[1]) feeding<=0;else position<=position+input_bytes;
        end
        if(output_valid) begin
            if(output_file) for(i=0;i<output_bytes;i=i+1) $fwrite(output_file,"%c",output_data[i*8+:8]);
            if(output_last) finished<=1;
        end
    end
    task begin_frame(input integer number);
        begin @(negedge clk);frame=number;position=0;feeding=1;finished=0;end
    endtask
    task complete_frame(input integer number);
        begin
            output_file=$fopen($sformatf("ddr_abort_%0d.spj",number),"wb");begin_frame(number);
            wait(!feeding);wait(finished);wait(!mem_active && dut.state==0);@(negedge clk);
            $fclose(output_file);output_file=0;
        end
    endtask
    task abort_and_drain;
        begin
            @(negedge clk);abort=1;feeding=0;
            repeat(3) @(negedge clk);abort=0;hold_write=0;
            wait(!recovering);wait(!mem_active);@(negedge clk);
            if(dut.state!=0 || dut.reference_valid) $fatal(1,"Abort did not clear local/reference state");
        end
    endtask
    initial begin
        $readmemh("threshold_input.mem",memory);$readmemh("threshold_lengths.mem",lengths);
        $readmemh("data/board_test/camera_quant.mem",quant);
        repeat(5) @(negedge clk);rst_n=1;
        for(i=0;i<128;i=i+1) begin @(negedge clk);q_valid=1;q_addr=i;q_value=quant[256+i][7:0];end
        @(negedge clk);q_valid=0;complete_frame(0);
        begin_frame(1);wait(dut.state==19 && mem_active);abort_and_drain;complete_frame(2);
        @(negedge clk);invalidate=1;@(negedge clk);invalidate=0;
        @(negedge clk);hold_write=1;begin_frame(3);wait(w_valid && !w_ready);abort_and_drain;
        if(zero_keep_beats==0) $fatal(1,"Write abort did not drain remaining keep=0 beats");
        complete_frame(4);
        @(negedge clk);hold_cmd=1;invalidate=1;@(negedge clk);invalidate=0;
        begin_frame(5);wait(cmd_valid && cmd_write && !cmd_ready);abort_and_drain;
        @(negedge clk);hold_cmd=0;complete_frame(6);
        @(negedge clk);fake_error=1;@(negedge clk);fake_error=0;
        repeat(5) @(negedge clk);
        if(!mem_fault || !recovering || input_ready || cmd_valid) $fatal(1,"Terminal memory error did not lock frame admission");
        rst_n=0;repeat(3) @(negedge clk);rst_n=1;repeat(2) @(negedge clk);
        if(mem_fault || recovering) $fatal(1,"Global reset failed to clear terminal fault");
        complete_frame(7);
        @(negedge clk);invalidate=1;@(negedge clk);invalidate=0;
        fork
            complete_frame(8);
            begin
                wait(frame==8 && dut.state==21 && mem_active);
                @(negedge clk);invalidate=1;@(negedge clk);invalidate=0;
            end
        join
        if(dut.reference_valid) $fatal(1,"Late quantization invalidate was overwritten by memory commit");
        complete_frame(9);
        // Both coefficient decoders may hold independently backpressured sparse
        // outputs. A local abort must reset both without leaving stale merge data.
        begin_frame(10);
        wait(dut.state==12 && dut.current_coefficient_valid && dut.reference_coefficient_valid);
        abort_and_drain;
        complete_frame(11);
        marker=$fopen("JPEG_THRESHOLD_DDR_ABORT_PASS.txt","w");
        $fdisplay(marker,"Read drain, held-write stability/keep0 drain, unaccepted command withdrawal, stale metadata invalidation, terminal fault/global reset, concurrent coefficient decoder abort");
        $fclose(marker);$finish;
    end
endmodule
