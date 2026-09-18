// Davinci A35T board bring-up: 50 MHz clock, active-low reset/key,
// active-high LEDs. Default heartbeat changes every 0.5 seconds.
module davinci_board_selftest_top #(
    parameter HALF_PERIOD_CYCLES = 25_000_000
) (
    input wire sys_clk,
    input wire sys_rst_n,
    input wire key0_n,
    output wire [3:0] led
);
    // Asynchronous assertion, synchronous release. INIT also holds reset
    // for the first two clock edges following FPGA configuration.
    (* ASYNC_REG = "TRUE" *) reg [1:0] reset_sync = 2'b00;
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            reset_sync <= 2'b00;
        else
            reset_sync <= {reset_sync[0], 1'b1};
    end
    wire internal_rst_n = reset_sync[1];

    (* ASYNC_REG = "TRUE" *) reg [1:0] key0_sync = 2'b11;
    reg [24:0] tick_count = 25'd0;
    reg heartbeat = 1'b0;
    always @(posedge sys_clk or negedge internal_rst_n) begin
        if (!internal_rst_n) begin
            key0_sync <= 2'b11;
            tick_count <= 25'd0;
            heartbeat <= 1'b0;
        end else begin
            key0_sync <= {key0_sync[0], key0_n};
            if (tick_count == HALF_PERIOD_CYCLES - 1) begin
                tick_count <= 25'd0;
                heartbeat <= ~heartbeat;
            end else begin
                tick_count <= tick_count + 1'b1;
            end
        end
    end

    // LED0/1 alternate, LED2 follows KEY0 press, LED3 indicates run state.
    assign led = !internal_rst_n ? 4'b0000 :
                 {1'b1, ~key0_sync[1], ~heartbeat, heartbeat};
endmodule
