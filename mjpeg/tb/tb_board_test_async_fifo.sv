`timescale 1ns/1ps
module tb_board_test_async_fifo;
    reg wclk=0,rclk=0,running=0,rst_n=0,send=0,drain=0;
    always #5 wclk=~wclk; // Current board encoding domain: 100MHz.
    always #8.333 if(running) rclk=~rclk;else rclk=0;
    wire ready,valid;
    wire guard_rst_n;
    board_test_usb_clock_guard #(.TIMEOUT_CYCLES(128)) guard(
        .sys_clk(wclk),.usb_clk(rclk),.sys_rst_n(rst_n),.run_rst_n(guard_rst_n));
    wire [7:0] data;
    reg s_valid=0,m_ready=0;
    integer produced=0,consumed=0,wraps=0,stalls=0,marker;
    reg [31:0] random_w=32'h8ba91237,random_r=32'h15acba91;
    reg [7:0] source_data=19;
    board_test_async_fifo #(.ADDRESS_BITS(4)) dut(
        .wclk(wclk),.wrst_n(rst_n),.s_data(source_data),.s_valid(s_valid),.s_ready(ready),
        .rclk(rclk),.rrst_n(rst_n),.m_data(data),.m_valid(valid),.m_ready(m_ready));
    reg held=0;
    reg [7:0] held_data;
    always @(negedge wclk) begin
        source_data=(produced*73+19)&255;
        random_w={random_w[30:0],random_w[31]^random_w[21]^random_w[1]^random_w[0]};
        if(!rst_n || !send) s_valid=0;
        else if(!s_valid || ready) s_valid=random_w[2:0]!=0;
    end
    always @(negedge rclk) begin
        random_r={random_r[30:0],random_r[31]^random_r[21]^random_r[1]^random_r[0]};
        m_ready=rst_n && (drain || random_r[3:0]<9);
    end
    always @(posedge wclk or negedge rst_n)
        if(!rst_n) produced=0;
        else if(s_valid && ready) produced=produced+1;
        else if(s_valid) stalls=stalls+1;
    always @(posedge rclk or negedge rst_n) begin
        if(!rst_n) begin consumed=0;held=0;end
        else begin
            if(held && (!valid || data!==held_data)) $fatal(1,"CDC front changed under stall");
            held=valid && !m_ready;held_data=data;
            if(valid && m_ready) begin
                if(consumed>=produced || data!==((consumed*73+19)&255))
                    $fatal(1,"CDC FIFO loss/duplicate/order: %0d, data=%0d",consumed,data);
                consumed=consumed+1;
                if(consumed%16==0) wraps=wraps+1;
            end
        end
    end
    initial begin
        #37;rst_n=1;send=1;
        repeat(100) @(negedge wclk);
        if(ready || produced!=16 || guard_rst_n) $fatal(1,"FIFO fills and guard holds reset without USB clock");
        // Reset a full queue with the reader clock absent: stale bytes vanish.
        rst_n=0;#31;running=1;#23;rst_n=1;
        repeat(40000) @(negedge wclk);
        if(!guard_rst_n) $fatal(1,"Running USB clock must release guard");
        running=0;repeat(200) @(negedge wclk);
        if(ready || guard_rst_n) $fatal(1,"Paused clock must backpressure source and assert guard");
        running=1;repeat(20000) @(negedge wclk);
        if(!guard_rst_n) $fatal(1,"USB clock guard did not recover");
        send=0;drain=1;repeat(100) @(negedge wclk);
        if(produced!=consumed || valid || consumed<10000 || stalls==0 || wraps<500)
            $fatal(1,"CDC FIFO insufficient coverage/drain");
        marker=$fopen("ASYNC_FIFO_PASS.txt","w");
        $fdisplay(marker,"%0d ordered bytes, %0d wraps, %0d full stalls; reset/full/paused clock/held front passed",consumed,wraps,stalls);
        $fclose(marker);$finish;
    end
endmodule
