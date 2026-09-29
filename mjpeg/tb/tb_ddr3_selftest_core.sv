`timescale 1ns/1ps
module tb_ddr3_selftest_core;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,ready=0,corrupt=0;
    wire cmd_valid,cmd_write,w_valid,w_last,r_ready,tx_valid;
    wire [27:0] cmd_addr;wire [13:0] cmd_bytes;
    wire [127:0] w_data;wire [15:0] w_keep;wire [7:0] tx_data;wire [3:0] led;
    reg cmd_ready=0,w_ready=0,r_valid=0,r_last=0,done=0,tx_ready=0;
    reg [127:0] r_data=0;
    ddr3_selftest_core #(.CLOCK_HZ(100),.REGIONS(4)) dut(
        .clk(clk),.rst_n(rst_n),.ready(ready),.fatal(1'b0),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_bytes(cmd_bytes),
        .w_data(w_data),.w_keep(w_keep),.w_valid(w_valid),.w_ready(w_ready),.w_last(w_last),
        .r_data(r_data),.r_valid(r_valid),.r_ready(r_ready),.r_last(r_last),.done(done),.error(1'b0),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.led(led));
    reg [127:0] memory[0:1539];
    reg active=0,is_write=0,finish_pending=0;
    integer cursor=0,remaining=0,cycles=0;
    function integer memory_index(input [27:0] addr);
        if(addr>=28'hfffffc0) memory_index=1024+((addr-28'hfffffc0)>>4);
        else if(addr>=28'h8000000) memory_index=1028+((addr-28'h8000000)>>4);
        else memory_index=addr>>4;
    endfunction
    always @(negedge clk) begin
        cmd_ready=rst_n && ready && !active && !finish_pending && $urandom_range(0,3)!=0;
        w_ready=rst_n && active && is_write && $urandom_range(0,3)!=0;
        tx_ready=rst_n && $urandom_range(0,3)!=0;
    end
    always @(posedge clk) begin
        if(!rst_n) begin active<=0;finish_pending<=0;r_valid<=0;done<=0;cycles<=0;end
        else begin
            cycles<=cycles+1;
            if(cycles>30000) $fatal(1,"Selftest timed out");
            done<=0;
            if(finish_pending) begin done<=1;finish_pending<=0;active<=0;end
            if(cmd_valid && cmd_ready) begin
                active<=1;is_write<=cmd_write;cursor<=memory_index(cmd_addr);remaining<=(cmd_bytes+15)>>4;
            end
            if(w_valid && w_ready) begin
                if(w_keep!=16'hffff || w_last!=(remaining==1)) $fatal(1,"Write framing");
                memory[cursor]<=w_data;cursor<=cursor+1;remaining<=remaining-1;
                if(w_last) finish_pending<=1;
            end
            if(active && !is_write && !finish_pending && (!r_valid || r_ready)) begin
                if(r_valid && r_ready) begin
                    cursor<=cursor+1;remaining<=remaining-1;r_valid<=0;
                    if(r_last) finish_pending<=1;
                end else if($urandom_range(0,3)!=0) begin
                    r_data<=memory[cursor]^((corrupt && cursor==0)?128'd1:128'd0);
                    r_valid<=1;r_last<=remaining==1;
                end
            end
        end
    end
    integer pos=0,packets=0;reg [383:0] packet=0;
    always @(posedge clk) begin
        if(!rst_n) begin pos<=0;packets<=0;end
        else if(tx_valid && tx_ready) begin
            packet[pos*8+:8]=tx_data;
            if(pos==47) begin
                if(packet[31:0]!=32'h54524444) $fatal(1,"Status magic");
                packets<=packets+1;pos<=0;
            end else pos<=pos+1;
        end
    end
    task run_case(input bit bad);
        begin
            @(negedge clk);rst_n=0;ready=0;corrupt=bad;
            repeat(5) @(negedge clk);rst_n=1;
            repeat(5) @(negedge clk);ready=1;
            wait(dut.state==7);repeat(150) @(negedge clk);
            if(dut.writes!=1540 || dut.reads!=1540 || packets==0) $fatal(1,"Counts/USB status");
            if(dut.errors!=(bad?1:0)) $fatal(1,"Mismatch accounting");
            if(bad && (dut.first_bad_addr!=0 || (dut.first_expected^dut.first_observed)!=1)) $fatal(1,"First error report");
            if(!bad && led[2:0]!=3'b101) $fatal(1,"Pass LED state");
        end
    endtask
    initial begin
        run_case(0);run_case(1);
        $display("DDR3_SELFTEST_CORE_PASS 2 patterns 1540 writes/reads each + intentional corruption detected");
        $finish;
    end
endmodule
