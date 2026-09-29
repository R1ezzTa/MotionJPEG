`timescale 1ns/1ps
// OV5640 16-bit-register SCCB, 7-bit address 0x3c. SDA is open drain.
// No generated internal clock: all logic runs in clk; tick is a clock enable.
module ov5640_sccb_master #(
    parameter integer CLK_HZ = 100000000,
    parameter integer SCCB_HZ = 100000
)(
    input wire clk, input wire rst_n,
    input wire start, input wire read_not_write,
    input wire [15:0] reg_addr, input wire [7:0] write_data,
    output reg busy, output reg done, output reg ack_error,
    output reg [7:0] read_data,
    output reg scl, input wire sda_i, output wire sda_drive_low
);
    localparam integer DIV = (CLK_HZ/(4*SCCB_HZ) < 1) ? 1 : CLK_HZ/(4*SCCB_HZ);
    localparam IDLE=0, START=1, BYTE=2, ACK=3, RESTART=4, STOP=5;
    reg [2:0] state;
    reg [1:0] phase;
    reg [2:0] bit_index, byte_index;
    reg [7:0] shift;
    reg [15:0] addr_latched;
    reg [7:0] data_latched;
    reg read_latched, receiving, sda_low;
    reg [31:0] divider;
    (* ASYNC_REG="TRUE" *) reg sda_meta, sda_sync;
    // Place the only physical IOBUF at the board top level.
    assign sda_drive_low = sda_low;
    always @(posedge clk) begin sda_meta <= sda_i; sda_sync <= sda_meta; end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; phase<=0; divider<=0; scl<=1; sda_low<=0;
            busy<=0; done<=0; ack_error<=0; read_data<=0;
            bit_index<=7; byte_index<=0; shift<=0; addr_latched<=0;
            data_latched<=0; read_latched<=0; receiving<=0;
        end else begin
            done<=0;
            if (state==IDLE) begin
                divider<=0; scl<=1; sda_low<=0;
                if(start) begin
                    busy<=1; ack_error<=0; addr_latched<=reg_addr;
                    data_latched<=write_data; read_latched<=read_not_write;
                    byte_index<=0; shift<=8'h78; receiving<=0;
                    bit_index<=7; phase<=0; state<=START;
                end
            end else if (divider==DIV-1) begin
                divider<=0;
                case(state)
                    START, RESTART: begin
                        case(phase)
                            0: begin scl<=0; sda_low<=0; phase<=1; end
                            1: begin scl<=1; phase<=2; end
                            2: begin sda_low<=1; phase<=3; end
                            3: begin scl<=0; phase<=0; state<=BYTE; end
                        endcase
                    end
                    BYTE: begin
                        case(phase)
                            0: begin scl<=0; sda_low<=receiving ? 1'b0 : ~shift[bit_index]; phase<=1; end
                            1: begin scl<=1; phase<=2; end
                            2: begin if(receiving) shift[bit_index]<=sda_sync; phase<=3; end
                            3: begin
                                scl<=0; phase<=0;
                                if(bit_index==0) state<=ACK;
                                else bit_index<=bit_index-1'b1;
                            end
                        endcase
                    end
                    ACK: begin
                        case(phase)
                            0: begin scl<=0; sda_low<=0; phase<=1; end // RX sends NACK for single-byte read
                            1: begin scl<=1; phase<=2; end
                            2: begin if(!receiving && sda_sync) ack_error<=1; phase<=3; end
                            3: begin
                                scl<=0; phase<=0; bit_index<=7;
                                if(ack_error || receiving || (!read_latched && byte_index==3)) begin
                                    if(receiving) read_data<=shift;
                                    state<=STOP;
                                end else begin
                                    byte_index<=byte_index+1'b1; state<=BYTE;
                                    case(byte_index)
                                        0: shift<=addr_latched[15:8];
                                        1: shift<=addr_latched[7:0];
                                        2: begin
                                            if(read_latched) begin shift<=8'h79; state<=RESTART; end
                                            else shift<=data_latched;
                                        end
                                        3: begin receiving<=1; shift<=0; end
                                        default: state<=STOP;
                                    endcase
                                end
                            end
                        endcase
                    end
                    STOP: begin
                        case(phase)
                            0: begin scl<=0; sda_low<=1; phase<=1; end
                            1: begin scl<=1; phase<=2; end
                            2: begin sda_low<=0; phase<=3; end
                            3: begin busy<=0; done<=1; phase<=0; state<=IDLE; end
                        endcase
                    end
                    default: state<=IDLE;
                endcase
            end else divider<=divider+1'b1;
        end
    end
endmodule
