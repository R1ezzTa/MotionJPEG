`timescale 1ns/1ps
// Direct channel/real core/DDR cache integration. No force or stub of the
// quantizer: all 128 q+reciprocal entries are accepted, aborted, and replayed.
module tb_ddr_channel_quant_recovery;
    reg clk=0,rst_n=0,q_valid=0,s_valid=0,s_abort=0,hold_write=0;
    always #5 clk=~clk;
    reg [6:0] q_addr=0;reg [7:0] q_value=0;reg [20:0] q_recip=0;
    reg [28:0] quant[0:383];reg [15:0] s_data=0;
    integer position=0,i,k,tick=0,replay_count=0,reset_edges=0;
    integer aborted_descs=0,good_descs=0,output_file=0,marker=0;
    reg frame_done=0;
    wire q_ready,tables_ready,config_error,busy,s_ready,m_valid,m_last,m_first,desc_valid;
    wire [127:0] m_data;wire [4:0] m_bytes;wire [31:0] m_frame_id,desc_id,desc_length;
    wire [7:0] desc_status;wire [63:0] desc_timestamp;wire [15:0] desc_width,desc_height;wire desc_gray;
    wire cmd_valid,cmd_ready,cmd_write,w_valid,w_ready,model_w_ready,w_last,r_valid,r_ready,r_last,mem_done,mem_error,mem_fault;
    wire [27:0] cmd_addr;wire [13:0] cmd_bytes;wire [127:0] w_data,r_data;wire [15:0] w_keep;
    wire [31:0] reads,writes,write_beats,read_beats,zero_keep_beats;
    assign w_ready=model_w_ready && !hold_write;
    mjpeg_channel #(.MAX_WIDTH(128),.RESTART_MCUS(4),.SPATIAL_SKIP(1),.SPATIAL_THRESHOLD(1),.SPATIAL_DDR(1)) dut(
        .clk(clk),.rst_n(rst_n),.enable(1'b1),.cfg_width(16'd128),.cfg_height(16'd8),.cfg_gray(1'b0),
        .cfg_skip_threshold(8'd32),.cfg_q_valid(q_valid),.cfg_q_ready(q_ready),.cfg_q_addr(q_addr),.cfg_q_value(q_value),.cfg_q_recip(q_recip),
        .tables_ready(tables_ready),.config_error(config_error),.busy(busy),
        .s_data(s_data),.s_valid(s_valid),.s_ready(s_ready),.s_sof(position==0),.s_eol(position%128==127),.s_eof(position==1023),.s_abort(s_abort),.s_timestamp({32'd0,tick[31:0]}),
        .m_data(m_data),.m_bytes(m_bytes),.m_first(m_first),.m_last(m_last),.m_valid(m_valid),.m_ready(1'b1),.m_frame_id(m_frame_id),.frame_done(frame_done),
        .desc_valid(desc_valid),.desc_ready(1'b1),.desc_frame_id(desc_id),.desc_length(desc_length),.desc_timestamp(desc_timestamp),.desc_width(desc_width),.desc_height(desc_height),.desc_gray(desc_gray),.desc_status(desc_status),
        .mem_cmd_valid(cmd_valid),.mem_cmd_ready(cmd_ready),.mem_cmd_write(cmd_write),.mem_cmd_addr(cmd_addr),.mem_cmd_bytes(cmd_bytes),
        .mem_w_data(w_data),.mem_w_keep(w_keep),.mem_w_valid(w_valid),.mem_w_ready(w_ready),.mem_w_last(w_last),
        .mem_r_data(r_data),.mem_r_valid(r_valid),.mem_r_ready(r_ready),.mem_r_last(r_last),.mem_done(mem_done),.mem_error(mem_error),.mem_fault(mem_fault));
    spatial_ddr_memory_model #(.SLOTS(2)) memory(
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_bytes(cmd_bytes),
        .w_data(w_data),.w_keep(w_keep),.w_valid(w_valid && !hold_write),.w_ready(model_w_ready),.w_last(w_last),
        .r_data(r_data),.r_valid(r_valid),.r_ready(r_ready),.r_last(r_last),.done(mem_done),.error(mem_error),.busy(),
        .reads(reads),.writes(writes),.write_beats(write_beats),.read_beats(read_beats),.zero_keep_beats(zero_keep_beats));
    always @(negedge dut.core_rst_n) if(rst_n) reset_edges=reset_edges+1;
    always @(posedge clk) begin
        tick=tick+1;if(tick>1000000) $fatal(1,"Quant recovery watchdog state%0d busy%b tables%b",dut.recovery,busy,tables_ready);
        frame_done<=m_valid && m_last;
        if(dut.replay && dut.core_q_ready) replay_count=replay_count+1;
        if(m_valid && output_file) for(k=0;k<m_bytes;k=k+1) $fwrite(output_file,"%c",m_data[k*8+:8]);
        if(desc_valid) begin
            $display("DESC id%0d status%0d length%0d",desc_id,desc_status,desc_length);
            if(desc_status==1) aborted_descs=aborted_descs+1;
            else if(desc_status==0) good_descs=good_descs+1;
            else $fatal(1,"Unexpected descriptor status%0d",desc_status);
        end
        if(mem_fault || config_error) $fatal(1,"Unexpected memory/config fault");
    end
    task feed_pixels(input integer count);
        integer sent;
        begin
            sent=0;
            while(sent<count) begin
                @(negedge clk);s_valid=1;position=sent;s_data={8'd128,sent[7:0]};
                @(posedge clk);while(!s_ready) @(posedge clk);
                sent=sent+1;
            end
            @(negedge clk);s_valid=0;
        end
    endtask
    task overflow_abort;
        begin @(negedge clk);s_valid=0;s_abort=1;repeat(3) @(negedge clk);s_abort=0;hold_write=0;end
    endtask
    task verify_restored(input integer expected_replays);
        integer cycles;
        begin
            cycles=0;
            while(busy || !tables_ready) begin
                @(negedge clk);cycles=cycles+1;
                if(cycles>1000) $fatal(1,"Recovery stuck state%0d busy%b tables%b cache_valid%h loaded%h",dut.recovery,busy,tables_ready,dut.cache_valid,dut.core.quant.loaded);
            end
            if(replay_count!=expected_replays || dut.cache_valid!={128{1'b1}}) $fatal(1,"Missing replay or cache entry %0d",replay_count);
            for(i=0;i<128;i=i+1) begin
                if(dut.core.quant.qt[i]!==quant[256+i][7:0] || dut.core.quant.rt[i]!==quant[256+i][28:8])
                    $fatal(1,"Restored quantization entry mismatch %0d",i);
            end
            $display("QUANT_RECOVERY %0d replay writes, reset_edges=%0d, all128 entries match",replay_count,reset_edges);
        end
    endtask
    initial begin
        $readmemh("data/board_test/camera_quant.mem",quant);
        repeat(5) @(negedge clk);rst_n=1;
        for(i=0;i<128;i=i+1) begin
            @(negedge clk);q_valid=1;q_addr=i;q_value=quant[256+i][7:0];q_recip=quant[256+i][28:8];
            @(posedge clk);while(!q_ready) @(posedge clk);
        end
        @(negedge clk);q_valid=0;wait(tables_ready);
        if(dut.cache_valid!={128{1'b1}}) $fatal(1,"Initial cache missing entries");
        feed_pixels(200);overflow_abort;wait(aborted_descs==1);verify_restored(128);
        output_file=$fopen("quant_recovery_frame1.spj","wb");feed_pixels(1024);wait(good_descs==1);wait(!busy);$fclose(output_file);output_file=0;
        // Rewriting a valid configuration entry is an authorized way to force
        // the following reference keyframe, ensuring there is a DDR write to abort.
        @(negedge clk);q_valid=1;q_addr=0;q_value=quant[256][7:0];q_recip=quant[256][28:8];
        @(posedge clk);while(!q_ready) @(posedge clk);@(negedge clk);q_valid=0;
        hold_write=1;
        fork
            feed_pixels(1024);
            begin wait(w_valid && !w_ready);overflow_abort;end
        join
        wait(aborted_descs==2);verify_restored(256);
        output_file=$fopen("quant_recovery_frame3.spj","wb");feed_pixels(1024);wait(good_descs==2);wait(!busy);$fclose(output_file);output_file=0;
        if(reset_edges!=2 || zero_keep_beats==0) $fatal(1,"Reset/drain coverage incomplete edges%0d keep0%0d",reset_edges,zero_keep_beats);
        marker=$fopen("DDR_CHANNEL_QUANT_RECOVERY_PASS.txt","w");
        $fdisplay(marker,"Two overflow aborts including held DDR write; exactly128 Q85 q+reciprocal writes per recovery, all128 actual quantizer RAM entries checked; next full frames succeed");
        $fclose(marker);$finish;
    end
endmodule
