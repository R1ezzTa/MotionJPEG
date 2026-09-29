// Writes all reference slots before reading any, to detect address aliasing.
// Two additional regions exercise the upper half and final bytes of DDR3.
// Raw USB status: "DDRT" + 11 little-endian uint32 fields, snapshotted atomically.
module ddr3_selftest_core #(parameter CLOCK_HZ=100000000,REGIONS=4052)(
    input clk,rst_n,ready,fatal,
    output cmd_valid,cmd_write,output [27:0] cmd_addr,output [13:0] cmd_bytes,input cmd_ready,
    output [127:0] w_data,output [15:0] w_keep,output w_valid,w_last,input w_ready,
    input [127:0] r_data,input r_valid,r_last,output r_ready,input done,error,
    output [7:0] tx_data,output tx_valid,input tx_ready,
    output [3:0] led
);
    localparam WAIT_CAL=0,W_CMD=1,W_DATA=2,W_DONE=3,R_CMD=4,R_DATA=5,R_DONE=6,COMPLETE=7;
    reg [3:0] state;
    reg [15:0] region;
    reg [9:0] beat;
    reg [31:0] writes,reads,errors,first_bad_addr,first_expected,first_observed;
    reg [31:0] ticks,calibration_ticks,test_ticks;
    wire [27:0] address=region==REGIONS-2?28'hfffffc0:
        region==REGIONS-1?28'h8000000:({12'd0,region}<<13);
    wire [13:0] length=region==REGIONS-2?14'd64:14'd8192;
    wire [9:0] beats=length>>4;
    wire [31:0] byte_address={4'd0,address}+{18'd0,beat,4'd0};
    function [127:0] pattern;
        input [31:0] a;
        begin
            pattern={((a+32'd12)^32'h196f38ab),((a+32'd8)^32'hc35a8f07),
                ((a+32'd4)^32'h5a5aa5a5),(a^32'hd3f16b29)};
        end
    endfunction
    assign cmd_valid=ready && !fatal && (state==W_CMD || state==R_CMD);
    assign cmd_write=state==W_CMD;
    assign cmd_addr=address;
    assign cmd_bytes=length;
    assign w_data=pattern(byte_address);
    assign w_keep=16'hffff;
    assign w_valid=state==W_DATA;
    assign w_last=beat==beats-1;
    assign r_ready=state==R_DATA;
    assign led={fatal || errors!=0,(state==COMPLETE && errors==0 && !fatal),
        (state!=WAIT_CAL && state!=COMPLETE),ready};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=WAIT_CAL;region<=0;beat<=0;writes<=0;reads<=0;errors<=0;
            first_bad_addr<=32'hffffffff;first_expected<=0;first_observed<=0;
            ticks<=0;calibration_ticks<=0;test_ticks<=0;
        end else begin
            ticks<=ticks+1'b1;
            if(state!=WAIT_CAL && state!=COMPLETE) test_ticks<=test_ticks+1'b1;
            if(state==WAIT_CAL && ready) begin calibration_ticks<=ticks;state<=W_CMD;end
            if(error || fatal) begin
                state<=COMPLETE;
                if(errors==0) begin errors<=1;first_bad_addr<=byte_address;end
            end else case(state)
                W_CMD:if(cmd_valid && cmd_ready) begin beat<=0;state<=W_DATA;end
                W_DATA:if(w_valid && w_ready) begin
                    writes<=writes+1'b1;
                    if(w_last) state<=W_DONE;else beat<=beat+1'b1;
                end
                W_DONE:if(done) begin
                    if(region==REGIONS-1) begin region<=0;state<=R_CMD;end
                    else begin region<=region+1'b1;state<=W_CMD;end
                end
                R_CMD:if(cmd_valid && cmd_ready) begin beat<=0;state<=R_DATA;end
                R_DATA:if(r_valid && r_ready) begin
                    reads<=reads+1'b1;
                    if(r_data!==pattern(byte_address) || r_last!=(beat==beats-1)) begin
                        errors<=errors+1'b1;
                        if(errors==0) begin
                            first_bad_addr<=byte_address;
                            first_expected<=pattern(byte_address);
                            first_observed<=r_data[31:0];
                        end
                    end
                    if(r_last) state<=R_DONE;else beat<=beat+1'b1;
                end
                R_DONE:if(done) begin
                    if(region==REGIONS-1) state<=COMPLETE;
                    else begin region<=region+1'b1;state<=R_CMD;end
                end
                default:begin end
            endcase
        end
    end
    reg [31:0] status_timer;
    reg [383:0] status_packet;
    reg [5:0] remaining;
    wire [31:0] status={20'd0,state,4'd0,fatal,(state==COMPLETE && errors==0 && !fatal),(state==COMPLETE),ready};
    assign tx_valid=remaining!=0;
    assign tx_data=status_packet[7:0];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin status_timer<=0;remaining<=0;status_packet<=0;end
        else begin
            if(status_timer<CLOCK_HZ/10) status_timer<=status_timer+1'b1;
            if(status_timer>=CLOCK_HZ/10 && remaining==0) begin
                status_timer<=0;remaining<=48;
                status_packet<={16'd0,region,calibration_ticks,test_ticks,first_observed,
                    first_expected,first_bad_addr,errors,reads,writes,4'd0,address,status,32'h54524444};
            end else if(tx_valid && tx_ready) begin
                remaining<=remaining-1'b1;status_packet<=status_packet>>8;
            end
        end
    end
endmodule
