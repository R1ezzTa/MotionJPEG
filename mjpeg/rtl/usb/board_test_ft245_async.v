// Conservative FT245 asynchronous FIFO timing at 50MHz; EEPROM unchanged.
// Data setup=40ns, RD#/WR# active=80ns, recovery/turnaround >=80ns.
module board_test_ft245_async(
    input clk,rst_n,
    inout [7:0] usb_data,
    input usb_rxf_n,usb_txe_n,
    output usb_rd_n,usb_wr_n,usb_oe_n,usb_siwu_n,
    output reg [7:0] rx_data, output reg rx_valid,
    input [7:0] tx_data,input tx_valid,output tx_ready
);
    localparam IDLE=0,RD=1,RECOVER=2,SETUP=3,WR=4,HOLD=5;
    reg [2:0] state;
    reg [2:0] count;
    reg [7:0] held_data;
    (* ASYNC_REG="TRUE" *) reg [1:0] rxf_sync,txe_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rxf_sync<=3;txe_sync<=3; end
        else begin rxf_sync<={rxf_sync[0],usb_rxf_n};txe_sync<={txe_sync[0],usb_txe_n}; end
    end
    assign usb_data=(state==SETUP || state==WR || state==HOLD) ? held_data : 8'bz;
    assign usb_rd_n=state!=RD;
    assign usb_wr_n=state!=WR;
    assign usb_oe_n=state!=RD; // Not required by async FIFO, matches bus direction.
    assign usb_siwu_n=1;
    assign tx_ready=(state==IDLE) && rxf_sync[1] && !txe_sync[1];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin state<=IDLE;count<=0;held_data<=0;rx_data<=0;rx_valid<=0; end
        else begin
            rx_valid<=0;
            case (state)
                IDLE: begin
                    if (!rxf_sync[1]) begin state<=RD;count<=3; end
                    else if (tx_valid && tx_ready) begin held_data<=tx_data;state<=SETUP;count<=1; end
                end
                RD: if (count==0) begin rx_data<=usb_data;rx_valid<=1;state<=RECOVER;count<=3; end
                    else count<=count-1'b1;
                RECOVER: if (count==0) state<=IDLE; else count<=count-1'b1;
                SETUP: if (count==0) begin state<=WR;count<=3; end else count<=count-1'b1;
                WR: if (count==0) begin state<=HOLD;count<=3; end else count<=count-1'b1;
                HOLD: if (count==0) state<=IDLE; else count<=count-1'b1;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
