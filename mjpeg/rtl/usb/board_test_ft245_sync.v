// FT232H FT245 synchronous FIFO. All transfers occur on CLKOUT rising edges.
// DATA/WR#/RD#/OE# launch on the preceding rising edge (full-cycle setup).
// TXE#/RXF# qualify actual transfers at the edge, not a delayed copy. A TXE#
// change can suppress a write without consuming the held byte. Never gate
// WR# combinationally with TXE#: that would violate the 7.5ns setup budget.
module board_test_ft245_sync #(parameter CLOCK_HZ=60000000)(
    input clk,rst_n,inout [7:0] usb_data,input usb_rxf_n,usb_txe_n,
    output usb_rd_n,usb_wr_n,usb_oe_n,usb_siwu_n,
    output reg [7:0] rx_data,output reg rx_valid,input rx_ready,
    input [7:0] tx_data,input tx_valid,output tx_ready,
    output reg stats_valid,output reg [223:0] stats_data
);
    localparam WRITE=0,RELEASE=1,OE_SETUP=2,READ=3,TURN=4;
    reg [2:0] state;
    (* IOB="TRUE" *) reg [7:0] held_data;
    (* IOB="TRUE" *) reg wr_n=1,rd_n=1,oe_n=1;
    // IOB requests one T flop per pin. Do not DONT_TOUCH these registers:
    // synthesis must remove feedback/replicate flops to pack the T outputs.
    // Preset releases the bus even when CLKOUT is absent.
    (* IOB="TRUE" *) reg [7:0] tristate_n=8'hff;
    reg held_valid,tail_valid;
    reg [7:0] tail_data;
    genvar bit_index;
    generate for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin: data_pins
        assign usb_data[bit_index]=tristate_n[bit_index]?1'bz:held_data[bit_index];
    end endgenerate
    // Initialized/preset I/O flops remain inactive even when CLKOUT is absent.
    // A combinational reset gate here would prevent packing into I/O flops.
    assign usb_wr_n=wr_n;
    assign usb_rd_n=rd_n;
    assign usb_oe_n=oe_n;
    assign usb_siwu_n=1;
    wire write_fire=state==WRITE && held_valid && !wr_n && !usb_txe_n;
    // Two-byte elastic front: RAM dequeue depends only on registered tail
    // occupancy, never on the late external TXE flag. In the steady state a
    // new FIFO byte replaces a transmitted head every clock. A blocked head
    // diverts one prefetched byte to the tail; both remain immutable.
    assign tx_ready=rst_n && !tail_valid;
    wire take=tx_valid && tx_ready;
    wire replace_head=!held_valid || write_fire;
    wire next_valid=replace_head?(tail_valid || take):held_valid;
    wire read_request=state==WRITE && !usb_rxf_n && (!rx_valid || rx_ready);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=TURN;held_data<=0;held_valid<=0;tristate_n<=8'hff;tail_valid<=0;tail_data<=0;
            wr_n<=1;rd_n<=1;oe_n<=1;rx_data<=0;rx_valid<=0;
        end else begin
            // Assign every cycle to avoid a late RXF flag on an I/O CE pin.
            wr_n<=1;rd_n<=1;oe_n<=1;
            held_valid<=next_valid;
            if(replace_head) begin
                if(tail_valid) begin held_data<=tail_data;tail_valid<=0;end
                else if(take) held_data<=tx_data;
            end else if(take) begin tail_data<=tx_data;tail_valid<=1;end
            if(rx_valid && rx_ready) rx_valid<=0;
            case(state)
                WRITE: begin
                    tristate_n<=0;rd_n<=1;oe_n<=1;
                    // With TXE low, an already-low WR consumes the head;
                    // otherwise the held head remains. Tail || take reduces
                    // to tail || tx_valid. Keep late TXE out of next_valid's
                    // feedback cone so it only gates the final WR decision.
                    wr_n<=usb_txe_n || !((held_valid && wr_n) || tail_valid || tx_valid);
                    if(read_request) begin
                        // Release FPGA data before FTDI enables its outputs.
                        tristate_n<=8'hff;wr_n<=1;state<=RELEASE;
                    end
                end
                RELEASE: begin
                    // FPGA T outputs have settled for an entire clock before
                    // OE# permits FTDI to drive (whose minimum enable is 0ns).
                    oe_n<=0;state<=OE_SETUP;
                end
                OE_SETUP: begin
                    // OE# has been low for a full clock before RD# goes low.
                    if(!usb_rxf_n) begin oe_n<=0;rd_n<=0;state<=READ;end
                    else begin oe_n<=1;state<=TURN;end
                end
                READ: begin
                    // One read per arbitration: room in rx_data was reserved
                    // before OE_SETUP. The command holds until FIFO accepts it.
                    if(!rd_n && !usb_rxf_n) begin rx_data<=usb_data;rx_valid<=1;end
                    rd_n<=1;oe_n<=1;state<=TURN;
                end
                TURN: begin tristate_n<=0;state<=WRITE;end
                default: begin state<=WRITE;tristate_n<=8'hff;wr_n<=1;rd_n<=1;oe_n<=1;end
            endcase
        end
    end
    // Disjoint counts in CLKOUT cycles. Writes count actual physical bytes,
    // not bytes queued into the CDC FIFO. RX arbitration includes turnaround.
    wire reading=state!=WRITE || read_request;
    wire available=held_valid || tx_valid;
    wire busy_cycle=!write_fire && !reading && available && !usb_txe_n;
    wire blocked=!write_fire && !reading && available && usb_txe_n;
    wire starved=!write_fire && !reading && !available;
    reg [31:0] ticks,window_id,writes,busy_ticks,blocked_ticks,empty_ticks,rx_ticks;
    reg event_valid;
    reg [4:0] events;
    // Register external qualifiers before wide arithmetic. Snapshot N covers
    // exactly N complete physical cycles and is emitted one cycle later.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin event_valid<=0;events<=0;end
        else begin event_valid<=1;events<={reading && !write_fire,starved,blocked,busy_cycle,write_fire};end
    end
    localparam [31:0] WINDOW_CLOCKS=CLOCK_HZ;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            ticks<=0;window_id<=0;writes<=0;busy_ticks<=0;blocked_ticks<=0;empty_ticks<=0;rx_ticks<=0;
            stats_valid<=0;stats_data<=0;
        end else begin
            stats_valid<=0;
            if(event_valid && ticks==CLOCK_HZ-1) begin
                stats_valid<=1;window_id<=window_id+1'b1;
                stats_data<={rx_ticks+{31'd0,events[4]},empty_ticks+{31'd0,events[3]},
                    blocked_ticks+{31'd0,events[2]},busy_ticks+{31'd0,events[1]},
                    writes+{31'd0,events[0]},WINDOW_CLOCKS,window_id+32'd1};
                ticks<=0;writes<=0;busy_ticks<=0;blocked_ticks<=0;empty_ticks<=0;rx_ticks<=0;
            end else if(event_valid) begin
                ticks<=ticks+1'b1;writes<=writes+events[0];busy_ticks<=busy_ticks+events[1];
                blocked_ticks<=blocked_ticks+events[2];empty_ticks<=empty_ticks+events[3];
                rx_ticks<=rx_ticks+events[4];
            end
        end
    end
endmodule
