`timescale 1ns/1ps
module tb_ddr3_burst_bridge;
    reg clk=0,ui_clk=0,rst_n=0,ui_rst=1,calibrated=0,ui_clock_enable=1;
    real ui_half=3.5;
    integer seed=1;
    initial begin
        if($value$plusargs("SEED=%d",seed)) begin end
        if($value$plusargs("UI_HALF=%f",ui_half)) begin end
    end
    always #5 clk=~clk;
    always #(ui_half) if(ui_clock_enable) ui_clk=~ui_clk;
    reg cmd_valid=0,cmd_write=0,w_valid=0,w_last=0,r_ready=0;
    reg [27:0] cmd_addr=0;
    reg [13:0] cmd_bytes=0;
    reg [127:0] w_data=0;
    reg [15:0] w_keep=0;
    wire cmd_ready,w_ready,r_valid,r_last,done,error,fatal;
    wire [127:0] r_data;
    wire [27:0] app_addr;
    wire [2:0] app_cmd;
    wire app_en,wdf_wren,wdf_end;
    wire [127:0] wdf_data;
    wire [15:0] wdf_mask;
    reg app_rdy=0,wdf_rdy=0,rd_valid=0,rd_end=1;
    reg [127:0] rd_data=0;
    ddr3_burst_bridge #(.FIFO_ADDR_BITS(4),.MAX_READ_OUTSTANDING(8)) dut(
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
        .cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_bytes(cmd_bytes),
        .w_data(w_data),.w_keep(w_keep),.w_valid(w_valid),.w_ready(w_ready),.w_last(w_last),
        .r_data(r_data),.r_valid(r_valid),.r_ready(r_ready),.r_last(r_last),
        .done(done),.error(error),.fatal(fatal),
        .ui_clk(ui_clk),.ui_rst(ui_rst),.init_calib_complete(calibrated),
        .app_addr(app_addr),.app_cmd(app_cmd),.app_en(app_en),.app_rdy(app_rdy),
        .app_wdf_data(wdf_data),.app_wdf_mask(wdf_mask),.app_wdf_wren(wdf_wren),
        .app_wdf_rdy(wdf_rdy),.app_wdf_end(wdf_end),
        .app_rd_data(rd_data),.app_rd_data_valid(rd_valid),.app_rd_data_end(rd_end));
    function [31:0] advance(input [31:0] value);
        advance={value[30:0],value[31]^value[21]^value[1]^value[0]};
    endfunction
    reg [31:0] ui_random=1,host_random=32'h3d0a7101;
    reg [7:0] memory[0:131071],expected[0:131071];
    integer write_addresses[0:16383],read_addresses[0:16383];
    reg [127:0] write_data_queue[0:16383];
    reg [15:0] write_mask_queue[0:16383];
    integer wc_head=0,wc_tail=0,wd_head=0,wd_tail=0,rc_head=0,rc_tail=0;
    integer model_byte,model_address,accepted_commands=0,accepted_data=0;
    integer max_outstanding=0,max_fifo_occupancy=0,transactions=0;
    reg held_command=0,held_data=0;
    reg [27:0] held_address;
    reg [2:0] held_kind;
    reg [127:0] held_word;
    reg [15:0] held_mask;
    integer forced_stall=0;
    always @(negedge ui_clk) begin
        if(!rst_n || ui_rst || !calibrated) begin
            app_rdy=0;wdf_rdy=0;rd_valid=0;rd_end=1;
        end else begin
            ui_random=advance(ui_random);
            app_rdy=ui_random[0] || ui_random[3];
            wdf_rdy=ui_random[4] && ui_random[7];
            rd_valid=(rc_head<rc_tail) && (ui_random[9] || ui_random[13]);
            rd_end=1;
            if(rd_valid) begin
                model_address=read_addresses[rc_head];
                for(model_byte=0;model_byte<16;model_byte=model_byte+1)
                    rd_data[8*model_byte+:8]=memory[model_address+model_byte];
            end
        end
    end
    always @(posedge ui_clk) begin
        if(!rst_n) begin
            wc_head=0;wc_tail=0;wd_head=0;wd_tail=0;rc_head=0;rc_tail=0;
            held_command=0;held_data=0;
        end else if(!ui_rst && calibrated && !fatal) begin
            if(held_command && (!app_en || app_addr!==held_address || app_cmd!==held_kind))
                $fatal(1,"MIG command changed under backpressure");
            if(held_data && (!wdf_wren || wdf_data!==held_word || wdf_mask!==held_mask || !wdf_end))
                $fatal(1,"MIG WDF changed under backpressure");
            held_command=app_en && !app_rdy;held_address=app_addr;held_kind=app_cmd;
            held_data=wdf_wren && !wdf_rdy;held_word=wdf_data;held_mask=wdf_mask;
            if(app_en && app_rdy) begin
                if(app_addr[2:0]!=0 || app_addr*2+15>=131072) $fatal(1,"MIG address units/alignment");
                accepted_commands=accepted_commands+1;
                if(app_cmd==0) begin
                    write_addresses[wc_tail]=app_addr*2;wc_tail=wc_tail+1;
                end else if(app_cmd==1) begin
                    read_addresses[rc_tail]=app_addr*2;rc_tail=rc_tail+1;
                end else $fatal(1,"MIG command opcode");
            end
            if(wdf_wren && wdf_rdy) begin
                if(!wdf_end) $fatal(1,"128-bit x16 BL8 word must end burst");
                accepted_data=accepted_data+1;
                write_data_queue[wd_tail]=wdf_data;write_mask_queue[wd_tail]=wdf_mask;wd_tail=wd_tail+1;
            end
            if(wc_head<wc_tail && wd_head<wd_tail) begin
                for(model_byte=0;model_byte<16;model_byte=model_byte+1)
                    if(!write_mask_queue[wd_head][model_byte])
                        memory[write_addresses[wc_head]+model_byte]=write_data_queue[wd_head][8*model_byte+:8];
                wc_head=wc_head+1;wd_head=wd_head+1;
            end
            if(rd_valid) rc_head=rc_head+1;
            if(dut.ui_read_outstanding>max_outstanding) max_outstanding=dut.ui_read_outstanding;
            if(dut.read_fifo_used>max_fifo_occupancy) max_fifo_occupancy=dut.read_fifo_used;
            if(dut.ui_read_outstanding>8 || dut.read_fifo_used>16)
                $fatal(1,"Unbounded read outstanding/FIFO occupancy");
        end
    end
    function [127:0] pattern(input integer base,input integer index,input integer salt);
        integer byte_index;
        begin
            for(byte_index=0;byte_index<16;byte_index=byte_index+1)
                pattern[8*byte_index+:8]=(base+index*16+byte_index)^(salt*37);
        end
    endfunction
    task ticks(input integer cycles);begin repeat(cycles) @(negedge clk);end endtask
    task issue(input bit writing,input integer address,input integer bytes_count);
        begin
            @(negedge clk);cmd_valid=1;cmd_write=writing;cmd_addr=address;cmd_bytes=bytes_count;
            @(posedge clk);while(!cmd_ready) @(posedge clk);
            @(negedge clk);cmd_valid=0;
        end
    endtask
    task terminal(input bit failing);
        begin
            while(!done) @(negedge clk);
            if(error!==failing) $fatal(1,"Terminal error mismatch");
            if(!failing && fatal) $fatal(1,"Normal transaction fatal");
            transactions=transactions+1;
            @(negedge clk);if(done || error) $fatal(1,"Terminal status must pulse");
        end
    endtask
    task write_burst(input integer address,input integer bytes_count,input integer salt,input bit zero_masks);
        integer index,words,byte_index,remaining;
        reg accepted;
        begin
            issue(1,address,bytes_count);words=(bytes_count+15)/16;
            for(index=0;index<words;index=index+1) begin
                remaining=bytes_count-index*16;
                w_data=pattern(address,index,salt);w_last=index==words-1;
                w_keep=remaining>=16?16'hffff:(16'hffff>>(16-remaining));
                if(zero_masks && index%3==1) w_keep=0;
                accepted=0;
                while(!accepted) begin
                    host_random=advance(host_random);w_valid=host_random[0] || host_random[5];
                    @(posedge clk);accepted=w_valid && w_ready;
                    @(negedge clk);
                end
                for(byte_index=0;byte_index<16;byte_index=byte_index+1)
                    if(w_keep[byte_index]) expected[address+index*16+byte_index]=w_data[8*byte_index+:8];
            end
            w_valid=0;terminal(0);
            if(wc_head!=wc_tail || wd_head!=wd_tail) $fatal(1,"Write done before both MIG channels accepted");
        end
    endtask
    task read_burst(input integer address,input integer bytes_count,input integer stalled_cycles);
        integer index,words,byte_index;
        reg accepted;
        begin
            issue(0,address,bytes_count);words=(bytes_count+15)/16;r_ready=0;
            ticks(stalled_cycles);
            if(done) $fatal(1,"Read done before host consumes last word");
            for(index=0;index<words;index=index+1) begin
                accepted=0;
                while(!accepted) begin
                    host_random=advance(host_random);r_ready=host_random[1] || host_random[7];
                    @(posedge clk);accepted=r_ready && r_valid;
                    if(accepted) begin
                        if(r_last!==(index==words-1)) $fatal(1,"Read last marker mismatch");
                        for(byte_index=0;byte_index<16;byte_index=byte_index+1)
                            if(r_data[8*byte_index+:8]!==expected[address+index*16+byte_index])
                                $fatal(1,"Read data mismatch word=%0d byte=%0d",index,byte_index);
                    end
                    @(negedge clk);
                end
            end
            r_ready=0;terminal(0);
        end
    endtask
    task common_reset;
        begin
            rst_n=0;ui_rst=1;calibrated=0;cmd_valid=0;w_valid=0;r_ready=0;
            ticks(8);rst_n=1;ticks(8);
            if(cmd_ready || app_en || wdf_wren || fatal) $fatal(1,"Calibration gating after common reset");
            ui_rst=0;ticks(10);calibrated=1;ticks(10);
            if(!cmd_ready || fatal) $fatal(1,"Common reset/calibration recovery");
        end
    endtask
    integer i,length,salt,marker,commands_before;
    initial begin
        #1;ui_random=32'hcafebab1^seed;host_random=32'h512719a1^seed;
        for(i=0;i<131072;i=i+1) begin memory[i]=8'ha5;expected[i]=8'ha5;end
        common_reset();
        write_burst(4096,1,1,0);read_burst(4096,1,100);
        write_burst(4112,16,2,0);read_burst(4112,16,0);
        write_burst(4128,17,3,0);read_burst(4128,17,10);
        write_burst(8192,8192,4,0);read_burst(8192,8192,600);
        write_burst(24576,8192,5,1);read_burst(24576,8192,400);
        for(i=0;i<24;i=i+1) begin
            host_random=advance(host_random);length=1+(host_random%8192);
            write_burst(32768,length,10+i,i%2);read_burst(32768,length,i%5);
        end
        if(max_fifo_occupancy<12 || max_outstanding<7) $fatal(1,"Read backpressure stress did not fill/reserve FIFO");
        // A stopped host cannot prevent an active transaction from terminating
        // with an error when the MIG loses calibration.
        issue(0,8192,8192);r_ready=0;ticks(12);calibrated=0;terminal(1);
        if(!fatal || cmd_ready || r_valid || w_ready) $fatal(1,"Calibration-loss sticky fatal/gating");
        calibrated=1;ticks(20);if(cmd_ready || !fatal) $fatal(1,"Calibration return silently cleared fatal");
        common_reset();issue(0,8192,8192);ticks(12);ui_clock_enable=0;calibrated=0;terminal(1);
        if(!fatal || cmd_ready) $fatal(1,"Stopped UI clock/calibration loss did not terminate");
        ui_clock_enable=1;
        common_reset();write_burst(65536,17,99,0);read_burst(65536,17,0);
        issue(1,66048,16);w_valid=0;ticks(8);ui_rst=1;terminal(1);
        if(!fatal || cmd_ready) $fatal(1,"UI-reset sticky fatal");
        common_reset();
        commands_before=accepted_commands;issue(1,4097,16);terminal(1);
        if(!fatal || accepted_commands!=commands_before) $fatal(1,"Invalid command reached MIG");
        common_reset();issue(1,70000,16);w_data=128'h1234;w_keep=0;w_last=0;w_valid=1;
        @(posedge clk);while(!w_ready) @(posedge clk);@(negedge clk);w_valid=0;terminal(1);
        if(!fatal) $fatal(1,"Malformed last marker not rejected");
        marker=$fopen("DDR3_BURST_BRIDGE_PASS.txt","w");
        $fdisplay(marker,"seed=%0d ui_half=%f transactions=%0d commands=%0d wdf=%0d max_read_outstanding=%0d max_fifo=%0d",seed,ui_half,transactions,accepted_commands,accepted_data,max_outstanding,max_fifo_occupancy);
        $fclose(marker);$finish;
    end
    initial begin #20000000;$fatal(1,"DDR3 bridge watchdog");end
endmodule
