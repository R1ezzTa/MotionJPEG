// CLKOUT disappears in asynchronous/reset bit-mode. Assert a shared reset
// after 1ms without a heartbeat, and release only when CLKOUT is running.
// The heartbeat itself uses the board reset, not the guarded reset, so it
// can restart the bridge. This also flushes partial records on mode changes.
module board_test_usb_clock_guard #(parameter TIMEOUT_CYCLES=50000)(
    input sys_clk,usb_clk,sys_rst_n,output run_rst_n
);
    reg [6:0] heartbeat_counter=0;
    (* ASYNC_REG="TRUE" *) reg [1:0] heartbeat_sync=0;
    reg heartbeat_seen=0,clock_alive=0;
    reg [31:0] silent_cycles=0;
    (* ASYNC_REG="TRUE" *) reg [2:0] sys_reset_pipe=0,usb_reset_pipe=0;
    always @(posedge sys_clk or negedge sys_rst_n)
        if(!sys_rst_n) sys_reset_pipe<=0;else sys_reset_pipe<={sys_reset_pipe[1:0],1'b1};
    always @(posedge usb_clk or negedge sys_rst_n)
        if(!sys_rst_n) usb_reset_pipe<=0;else usb_reset_pipe<={usb_reset_pipe[1:0],1'b1};
    wire sys_local_rst_n=sys_reset_pipe[2],usb_local_rst_n=usb_reset_pipe[2];
    always @(posedge usb_clk or negedge usb_local_rst_n)
        if(!usb_local_rst_n) heartbeat_counter<=0;else heartbeat_counter<=heartbeat_counter+1'b1;
    always @(posedge sys_clk or negedge sys_local_rst_n) begin
        if(!sys_local_rst_n) begin heartbeat_sync<=0;heartbeat_seen<=0;silent_cycles<=0;clock_alive<=0;end
        else begin
            heartbeat_sync<={heartbeat_sync[0],heartbeat_counter[6]};
            if(heartbeat_sync[1]!=heartbeat_seen) begin
                heartbeat_seen<=heartbeat_sync[1];silent_cycles<=0;clock_alive<=1;
            end else if(silent_cycles<TIMEOUT_CYCLES) silent_cycles<=silent_cycles+1'b1;
            else clock_alive<=0;
        end
    end
    // clock_alive is already asynchronously cleared by the board reset.
    // Drive reset synchronizers from a flop, without a combinational gate.
    assign run_rst_n=clock_alive;
endmodule
