`timescale 1ns/1ps
// Codec-side DDR command model: independent randomized command/W/R stalls.
// Every accepted command completes exactly once; abort keep=0 beats are legal.
module spatial_ddr_memory_model #(
    parameter SLOTS=4050,RANDOM_STALLS=1,SEED=16'h8ab9
)(
    input clk,rst_n,
    input cmd_valid,output cmd_ready,input cmd_write,input [27:0] cmd_addr,input [13:0] cmd_bytes,
    input [127:0] w_data,input [15:0] w_keep,input w_valid,output w_ready,input w_last,
    output [127:0] r_data,output r_valid,input r_ready,output r_last,
    output reg done=0,error=0,output busy,
    output reg [31:0] reads=0,writes=0,write_beats=0,read_beats=0,zero_keep_beats=0
);
    reg [127:0] memory[0:SLOTS*512-1];
    reg active=0,writing=0,read_valid=0;
    reg [27:0] address=0;
    reg [9:0] total_beats=0,position=0;
    reg [15:0] random_state=SEED;
    integer lane;
    assign busy=active;
    assign cmd_ready=rst_n && !active && !done && (!RANDOM_STALLS || random_state[2:0]!=0);
    assign w_ready=rst_n && active && writing && (!RANDOM_STALLS || random_state[5:3]!=0);
    assign r_valid=read_valid;
    assign r_data=memory[(address>>4)+position];
    assign r_last=position==total_beats-1;
    reg held_w=0;reg [127:0] held_data;reg [15:0] held_keep;reg held_last;
    always @(posedge clk) begin
        if(!rst_n) begin
            active<=0;writing<=0;read_valid<=0;done<=0;error<=0;position<=0;total_beats<=0;
            reads<=0;writes<=0;write_beats<=0;read_beats<=0;zero_keep_beats<=0;held_w<=0;
        end else begin
            done<=0;error<=0;
            random_state<={random_state[14:0],random_state[15]^random_state[13]^random_state[12]^random_state[10]};
            if(held_w && (!w_valid || {w_data,w_keep,w_last}!={held_data,held_keep,held_last}))
                $fatal(1,"DDR W changed while backpressured");
            held_w<=w_valid && !w_ready;
            held_data<=w_data;held_keep<=w_keep;held_last<=w_last;
            if(cmd_valid && cmd_ready) begin
                if(cmd_addr[3:0]!=0 || cmd_bytes==0 || cmd_bytes>8192 || cmd_addr+cmd_bytes>SLOTS*8192)
                    $fatal(1,"DDR command range/alignment addr=%0d bytes=%0d",cmd_addr,cmd_bytes);
                active<=1;writing<=cmd_write;address<=cmd_addr;position<=0;
                total_beats<=({1'b0,cmd_bytes}+15)>>4;
                if(cmd_write) writes<=writes+1;else reads<=reads+1;
            end
            if(active && writing && w_valid && w_ready) begin
                if(w_last!==(position==total_beats-1)) $fatal(1,"DDR W last/count mismatch");
                for(lane=0;lane<16;lane=lane+1)
                    if(w_keep[lane]) memory[(address>>4)+position][lane*8+:8]<=w_data[lane*8+:8];
                write_beats<=write_beats+1;
                if(w_keep==0) zero_keep_beats<=zero_keep_beats+1;
                if(position==total_beats-1) begin active<=0;done<=1;end
                else position<=position+1'b1;
            end
            if(active && !writing && !read_valid && (!RANDOM_STALLS || random_state[8:6]!=0)) read_valid<=1;
            if(read_valid && r_ready) begin
                read_valid<=0;read_beats<=read_beats+1;
                if(position==total_beats-1) begin active<=0;done<=1;end
                else position<=position+1'b1;
            end
        end
    end
endmodule
