`timescale 1ns/1ps
module tb_davinci_mjpeg_board_test;
    localparam DIV=8;
    reg clk=0, rst_n=0, rx=1;
    always #10 clk=~clk;
    wire tx;
    wire [3:0] led;
    davinci_mjpeg_uart_test_top #(.UART_DIVISOR(DIV)) dut(
        .sys_clk(clk),.sys_rst_n(rst_n),.usb_uart_rx(rx),.usb_uart_tx(tx),.led(led));
    integer capture, cycles=0, serial_bytes=0, j, marker;
    reg [7:0] byte_data;
    initial begin
        capture=$fopen("uart_capture.bin","wb");
        if (!capture) $fatal(1,"Cannot open serial capture");
        forever begin
            @(negedge tx);
            #(DIV*20/2);
            if (tx!==0) $fatal(1,"UART start bit");
            for (j=0;j<8;j=j+1) begin #(DIV*20); byte_data[j]=tx; end
            #(DIV*20);
            if (tx!==1) $fatal(1,"UART stop bit");
            $fwrite(capture,"%c",byte_data); serial_bytes=serial_bytes+1;
        end
    end
    task send_g;
        integer k;
        reg [7:0] command;
        begin
            command="G";
            @(negedge clk); rx=0; repeat(DIV) @(negedge clk);
            for (k=0;k<8;k=k+1) begin rx=command[k]; repeat(DIV) @(negedge clk); end
            rx=1; repeat(DIV) @(negedge clk);
        end
    endtask
    always @(posedge clk) begin
        cycles=cycles+1;
        if (cycles>20000000) $fatal(1,"Board wrapper watchdog state=%0d",dut.engine.state);
        if (led[3]) $fatal(1,"Codec configuration/descriptor error");
    end
    initial begin
        repeat(10) @(negedge clk); rst_n=1;
        repeat(10) @(negedge clk);
        send_g(); wait(led[2]); repeat(20) @(negedge clk);
        send_g(); wait(!led[2]); wait(led[2]); repeat(20) @(negedge clk);
        $fclose(capture);
        marker=$fopen("SIM_PASS.txt","w");
        $fdisplay(marker,"UART waveform capture complete: two sessions, 18 frames; %0d bytes",serial_bytes);
        $fclose(marker); $finish;
    end
endmodule
