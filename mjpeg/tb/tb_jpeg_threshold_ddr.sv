`timescale 1ns/1ps
module tb_jpeg_threshold_ddr #(
    parameter FRAME_COUNT=12,FRAME_STRIDE=1024,MEM_SLOTS=2,WIDTH=128,HEIGHT=8,WATCHDOG=1000000,
    INPUT_FILE="threshold_input.mem",LENGTH_FILE="threshold_lengths.mem",VALUE_FILE="threshold_values.mem",
    OUTPUT_PATTERN="threshold_%0d.spj",PASS_FILE="JPEG_THRESHOLD_DDR_PASS.txt",TRACE_FILE="",
    parameter EXPECT_EARLY_REJECTS=0,ADAPTIVE_TEST=0,ADAPTIVE_BUDGET=384,SOURCE_GAP=160,PRESSURE_TEST=0,MODE_FILE=""
);
    reg clk=0,rst_n=0,abort=0;
    always #5 clk=~clk;
    reg [7:0] memory[0:FRAME_COUNT*FRAME_STRIDE-1];reg [31:0] lengths[0:FRAME_COUNT-1],thresholds[0:FRAME_COUNT-1];reg [28:0] quant[0:383];
    reg [7:0] threshold=0;reg q_valid=0;reg [6:0] q_addr=0;reg [7:0] q_value=0;
    reg adaptive=0;reg [31:0] modes[0:FRAME_COUNT-1];
    integer frame=0,position=0,output_file=0,i,k,ticks=0,marker=0,trace=0,frame_start_tick=0;
    integer coefficient_ticks=0,early_rejects=0,unfinished_rejects=0,decoder_errors=0;
    integer budget_rejects=0;
    integer next_source_tick=0;
    reg source_offer=1;
    reg feeding=0,finished=0,output_ready=0;reg [15:0] random_state=16'hac19;
    reg [127:0] input_data;reg [4:0] input_bytes;
    wire input_ready,output_valid,output_last,recovering,mem_fault,mem_active;
    wire [127:0] output_data;wire [4:0] output_bytes;
    wire cmd_valid,cmd_ready,cmd_write,w_valid,w_ready,w_last,r_valid,r_ready,r_last,mem_done,mem_error;
    wire [27:0] cmd_addr;wire [13:0] cmd_bytes;wire [127:0] w_data,r_data;wire [15:0] w_keep;
    wire [31:0] reads,writes,write_beats,read_beats,zero_keep_beats;
    always @* begin
        input_data=0;input_bytes=(lengths[frame]-position>=16)?16:lengths[frame]-position;
        for(k=0;k<16;k=k+1) input_data[k*8+:8]=memory[frame*FRAME_STRIDE+position+k];
    end
    jpeg_spatial_skip_ddr #(.REFRESH_PERIOD(64),.ADAPTIVE_ENABLE(ADAPTIVE_TEST),.ADAPTIVE_COMPARE_CYCLES(ADAPTIVE_BUDGET)) dut(
        .clk(clk),.rst_n(rst_n),.invalidate(q_valid),.abort(abort),.recovering(recovering),.mem_fault(mem_fault),.mem_active(mem_active),
        .frame_id(frame),.width(WIDTH[15:0]),.height(HEIGHT[15:0]),.gray(1'b0),
        .cfg_threshold(threshold),.cfg_adaptive(adaptive),.input_pressure(PRESSURE_TEST!=0),.cfg_q_valid(q_valid),.cfg_q_addr(q_addr),.cfg_q_value(q_value),
        .s_data(input_data),.s_bytes(input_bytes),.s_last(position+input_bytes==lengths[frame]),
        .s_valid(feeding && source_offer),.s_ready(input_ready),.m_data(output_data),.m_bytes(output_bytes),
        .m_last(output_last),.m_valid(output_valid),.m_ready(output_ready),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_bytes(cmd_bytes),
        .w_data(w_data),.w_keep(w_keep),.w_valid(w_valid),.w_ready(w_ready),.w_last(w_last),
        .r_data(r_data),.r_valid(r_valid),.r_ready(r_ready),.r_last(r_last),.mem_done(mem_done),.mem_error(mem_error));
    spatial_ddr_memory_model #(.SLOTS(MEM_SLOTS)) ram(
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_bytes(cmd_bytes),
        .w_data(w_data),.w_keep(w_keep),.w_valid(w_valid),.w_ready(w_ready),.w_last(w_last),
        .r_data(r_data),.r_valid(r_valid),.r_ready(r_ready),.r_last(r_last),.done(mem_done),.error(mem_error),.busy(),
        .reads(reads),.writes(writes),.write_beats(write_beats),.read_beats(read_beats),.zero_keep_beats(zero_keep_beats));
    always @(negedge clk) begin
        source_offer<=!ADAPTIVE_TEST || ticks>=next_source_tick;
        random_state={random_state[14:0],random_state[15]^random_state[13]^random_state[12]^random_state[10]};
        output_ready=random_state[2:0]!=0;
    end
    always @(posedge clk) if(rst_n) begin
        ticks=ticks+1;if(ticks>WATCHDOG) $fatal(1,"Threshold DDR watchdog frame %0d state %0d",frame,dut.state);
        if(mem_fault) $fatal(1,"DDR memory fault");
        if(feeding && input_ready && source_offer) begin
            next_source_tick=ticks+(ADAPTIVE_TEST?SOURCE_GAP:0);
            if(position+input_bytes==lengths[frame]) feeding<=0;else position<=position+input_bytes;
        end
        if(output_valid && output_ready) begin
            for(i=0;i<output_bytes;i=i+1) $fwrite(output_file,"%c",output_data[i*8+:8]);
            if(output_last) finished<=1;
        end
    end
    // Validate the fast DATA decision on the exact clock its pipeline result
    // becomes available, and ensure the following synchronous reset clears both
    // decoders. Each group then starts with independent fresh DC histories.
    always @(posedge clk) if(rst_n) begin
        if(dut.state==12) coefficient_ticks=coefficient_ticks+1;
        if(dut.state==12 && (dut.current_error || dut.reference_error)) decoder_errors=decoder_errors+1;
        if(dut.state==12 && (dut.comparison_failed || dut.comparison_expired)) begin
            if(dut.comparison_expired) budget_rejects=budget_rejects+1;
            early_rejects=early_rejects+1;
            if(!dut.current_done || !dut.reference_done) unfinished_rejects=unfinished_rejects+1;
            #1;
            if(dut.state!=20 || dut.copy_group || dut.comparison_valid1 || dut.comparison_valid2 ||
               dut.coefficient_current_pending || dut.coefficient_reference_pending)
                $fatal(1,"Failed coefficient did not immediately select clean DATA frame%0d",frame);
        end else if(dut.state!=11 && dut.state!=12) begin
            #1;
            if(dut.coefficient_decoders.current_decoder.active || dut.coefficient_decoders.reference_decoder.active ||
               dut.current_coefficient_valid || dut.reference_coefficient_valid)
                $fatal(1,"Inactive coefficient decoder retained stale output frame%0d",frame);
        end
    end
    initial begin
        $readmemh(INPUT_FILE,memory);$readmemh(LENGTH_FILE,lengths);
        $readmemh(VALUE_FILE,thresholds);$readmemh("data/board_test/camera_quant.mem",quant);
        if(ADAPTIVE_TEST) $readmemh(MODE_FILE,modes);
        repeat(5) @(negedge clk);rst_n=1;
        for(i=0;i<128;i=i+1) begin @(negedge clk);q_valid=1;q_addr=i;q_value=quant[256+i][7:0];end
        @(negedge clk);q_valid=0;
        if(TRACE_FILE!="") begin trace=$fopen(TRACE_FILE,"w");$fwrite(trace,"[\n");end
        for(frame=0;frame<FRAME_COUNT;frame=frame+1) begin
            output_file=$fopen($sformatf(OUTPUT_PATTERN,frame),"wb");
            @(negedge clk);threshold=thresholds[frame];adaptive=ADAPTIVE_TEST?modes[frame][0]:1'b0;
            position=0;feeding=1;finished=0;frame_start_tick=ticks;
            wait(!feeding);wait(finished);wait(!mem_active);repeat(2) @(negedge clk);$fclose(output_file);
            if(trace) begin
                if(frame!=0) $fwrite(trace,",\n");
                $fwrite(trace,"{\"frame_id\":%0d,\"ticks\":%0d,\"memory_reads_total\":%0d,\"memory_writes_total\":%0d}",frame,ticks-frame_start_tick,reads,writes);
                $display("DDR_CAPTURE frame %0d cache_ticks=%0d ideal_cache_fps=%f",frame,ticks-frame_start_tick,100000000.0/(ticks-frame_start_tick));
            end
        end
        if(trace) begin $fwrite(trace,"\n]\n");$fclose(trace);end
        if(reads==0 || writes==0 || zero_keep_beats!=0) $fatal(1,"DDR read/write coverage");
        if(ADAPTIVE_TEST && ADAPTIVE_BUDGET==8 && budget_rejects==0) $fatal(1,"No comparison budget expiry exercised");
        if(EXPECT_EARLY_REJECTS!=0 && (unfinished_rejects<EXPECT_EARLY_REJECTS || decoder_errors<2))
            $fatal(1,"Insufficient early rejection/malformed coverage rejects=%0d errors=%0d",unfinished_rejects,decoder_errors);
        $display("DDR_COMPARE ticks=%0d earlyrejects=%0d unfinished=%0d malformed=%0d budget_rejects=%0d",coefficient_ticks,early_rejects,unfinished_rejects,decoder_errors,budget_rejects);
        marker=$fopen(PASS_FILE,"w");
        $fdisplay(marker,"%0d exact fixture packets, DDR commands %0d read/%0d write, randomized W/R/output stalls",FRAME_COUNT,reads,writes);
        $fclose(marker);$finish;
    end
endmodule

module tb_jpeg_threshold_ddr_early;
    tb_jpeg_threshold_ddr #(.FRAME_COUNT(9),.FRAME_STRIDE(4096),.WATCHDOG(1000000),.EXPECT_EARLY_REJECTS(2),
        .INPUT_FILE("early_input.mem"),.LENGTH_FILE("early_lengths.mem"),.VALUE_FILE("early_values.mem"),
        .OUTPUT_PATTERN("early_%0d.spj"),.PASS_FILE("JPEG_THRESHOLD_DDR_EARLY_PASS.txt"),.TRACE_FILE("early_throughput.json")) test();
endmodule

module tb_jpeg_threshold_ddr_camera_capture;
    tb_jpeg_threshold_ddr #(.FRAME_COUNT(2),.FRAME_STRIDE(1048576),.MEM_SLOTS(4050),.WIDTH(1920),.HEIGHT(1080),.WATCHDOG(10000000),
        .INPUT_FILE("captured_input.mem"),.LENGTH_FILE("captured_lengths.mem"),.VALUE_FILE("captured_values.mem"),
        .OUTPUT_PATTERN("captured_%0d.spj"),.PASS_FILE("JPEG_THRESHOLD_DDR_CAPTURE_PASS.txt"),.TRACE_FILE("captured_throughput.json")) test();
endmodule

module tb_jpeg_threshold_ddr_dense;
    tb_jpeg_threshold_ddr #(.FRAME_COUNT(4),.FRAME_STRIDE(4096),
        .INPUT_FILE("dense_input.mem"),.LENGTH_FILE("dense_lengths.mem"),.VALUE_FILE("dense_values.mem"),
        .OUTPUT_PATTERN("dense_%0d.spj"),.PASS_FILE("JPEG_THRESHOLD_DDR_DENSE_PASS.txt")) test();
endmodule

module tb_jpeg_threshold_ddr_full;
    tb_jpeg_threshold_ddr #(.FRAME_COUNT(4),.FRAME_STRIDE(131072),.MEM_SLOTS(4050),.WIDTH(1920),.HEIGHT(1080),.WATCHDOG(10000000),
        .INPUT_FILE("full_input.mem"),.LENGTH_FILE("full_lengths.mem"),.VALUE_FILE("full_values.mem"),
        .OUTPUT_PATTERN("full_%0d.spj"),.PASS_FILE("JPEG_THRESHOLD_DDR_FULL_PASS.txt")) test();
endmodule
