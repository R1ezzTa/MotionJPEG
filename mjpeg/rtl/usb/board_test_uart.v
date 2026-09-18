// Temporary board-test transport, 8N1. Not the production USB FIFO interface.
module board_test_uart_tx #(parameter DIVISOR=434)(
    input clk, rst_n, input [7:0] data, input valid,
    output ready, output tx
);
    reg [9:0] shift;
    reg [15:0] count;
    reg [3:0] bit_index;
    reg active;
    assign ready = !active;
    assign tx = active ? shift[0] : 1'b1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin shift<=10'h3ff; count<=0; bit_index<=0; active<=0; end
        else if (!active) begin
            if (valid) begin shift<={1'b1,data,1'b0}; count<=DIVISOR-1; bit_index<=0; active<=1; end
        end else if (count==0) begin
            count<=DIVISOR-1;
            shift<={1'b1,shift[9:1]};
            if (bit_index==9) active<=0;
            else bit_index<=bit_index+1'b1;
        end else count<=count-1'b1;
    end
endmodule

module board_test_uart_rx #(parameter DIVISOR=434)(
    input clk, rst_n, rx, output reg [7:0] data, output reg valid
);
    (* ASYNC_REG="TRUE" *) reg [1:0] rx_sync;
    reg [15:0] count;
    reg [3:0] state;
    reg [7:0] shift;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_sync<=2'b11;
        else rx_sync<={rx_sync[0],rx};
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin count<=0; state<=0; shift<=0; data<=0; valid<=0; end
        else begin
            valid<=0;
            if (state==0) begin
                if (!rx_sync[1]) begin state<=1; count<=DIVISOR/2-1; end
            end else if (count!=0) count<=count-1'b1;
            else if (state==1) begin
                if (rx_sync[1]) state<=0;
                else begin state<=2; count<=DIVISOR-1; end
            end else if (state<=9) begin
                shift[state-2]<=rx_sync[1]; state<=state+1'b1; count<=DIVISOR-1;
            end else begin
                if (rx_sync[1]) begin data<=shift; valid<=1; end
                state<=0;
            end
        end
    end
endmodule
