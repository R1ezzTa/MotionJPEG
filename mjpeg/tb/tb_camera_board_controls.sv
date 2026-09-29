`timescale 1ns/1ps
module tb_camera_board_controls;
    reg clk=0,rst_n=0,ready=1,streaming=0,fault=0,light_on=0;
    reg [3:0] keys=15;
    reg [7:0] rx=0;
    reg rx_valid=0;
    wire run_requested,light_start,light_cancel;
    wire [1:0] quality;
    wire [7:0] threshold;
    wire adaptive;
    wire [7:0] denoise,disabled_denoise,disabled_threshold;
    wire disabled_adaptive,nr_run;
    wire [1:0] nr_quality;
    wire [1:0] pp_mode,disabled_mode;
    wire [7:0] binary_threshold,edge_threshold,disabled_binary,disabled_edge;
    wire [3:0] led;
    integer starts=0,cancels=0,marker;
    always #5 clk=~clk;
    camera_board_controls #(.CLOCK_HZ(100),.DEBOUNCE_CYCLES(4),.COMMAND_TIMEOUT_CYCLES(50)) dut(
        .clk(clk),.reset_n(rst_n),.key_n(keys),.rx_data(rx),.rx_valid(rx_valid),
        .streaming(streaming),.camera_ready(ready),.active_quality(quality),
        .light_on(light_on),.fault(fault),.run_requested(run_requested),
        .quality_requested(quality),.spatial_threshold_requested(threshold),
        .spatial_adaptive_requested(adaptive),
        .denoise_strength_requested(disabled_denoise),
        .preprocess_mode_requested(disabled_mode),.binary_threshold_requested(disabled_binary),.edge_threshold_requested(disabled_edge),
        .light_start(light_start),.light_cancel(light_cancel),.led(led));
    camera_board_controls #(.CLOCK_HZ(100),.DEBOUNCE_CYCLES(4),.COMMAND_TIMEOUT_CYCLES(50),
        .SPATIAL_COMMANDS(0),.DENOISE_COMMANDS(1),.PREPROCESS_COMMANDS(1)) nr_controls(
        .clk(clk),.reset_n(rst_n),.key_n(keys),.rx_data(rx),.rx_valid(rx_valid),
        .streaming(streaming),.camera_ready(ready),.active_quality(nr_quality),
        .light_on(light_on),.fault(fault),.run_requested(nr_run),.quality_requested(nr_quality),
        .spatial_threshold_requested(disabled_threshold),.spatial_adaptive_requested(disabled_adaptive),
        .denoise_strength_requested(denoise),.preprocess_mode_requested(pp_mode),
        .binary_threshold_requested(binary_threshold),.edge_threshold_requested(edge_threshold),
        .light_start(),.light_cancel(),.led());
    always @(posedge clk) if(rst_n) begin
        if(light_start) starts=starts+1;
        if(light_cancel) cancels=cancels+1;
    end
    task tick(input integer n);begin repeat(n) @(negedge clk);end endtask
    task press(input [3:0] mask);begin keys=15^mask;tick(12);keys=15;tick(12);end endtask
    task send_byte(input [7:0] value);begin rx=value;rx_valid=1;tick(1);rx_valid=0;tick(1);end endtask
    initial begin
        tick(3);rst_n=1;tick(12);
        if(run_requested || quality!=2 || threshold!=0 || led!=4'b0100) $fatal(1,"Default state/LED");
        keys=14;tick(2);keys=15;tick(2);keys=14;tick(2);keys=15;tick(12);
        if(run_requested) $fatal(1,"Contact bounce toggled run");
        keys=14;tick(100);
        if(!run_requested) $fatal(1,"Long press not accepted exactly once");
        keys=15;tick(12);press(1);
        if(run_requested) $fatal(1,"Second KEY0 press did not stop");
        press(2);if(quality!=0 || led[2:1]!=0) $fatal(1,"Q60 LED");
        press(2);if(quality!=1 || led[2:1]!=1) $fatal(1,"Q75 LED");
        press(2);if(quality!=2 || led[2:1]!=2) $fatal(1,"Q85 LED");
        keys=11;tick(100);keys=15;tick(12);
        if(starts!=1) $fatal(1,"Held KEY2 retriggered light timer");
        light_on=1;tick(2);if(!led[3]) $fatal(1,"Light LED");light_on=0;
        press(13); // KEY0 + KEY2 + KEY3: stop/cancel wins.
        if(run_requested || starts!=1) $fatal(1,"STOP priority");
        ready=0;press(4);if(starts!=1) $fatal(1,"Light admitted before initialization");
        ready=1;rx="C";rx_valid=1;tick(1);rx_valid=0;tick(1);
        if(!run_requested) $fatal(1,"Legacy USB START");
        rx="S";rx_valid=1;tick(1);rx_valid=0;tick(1);
        if(run_requested || cancels<3) $fatal(1,"Legacy USB STOP/cancel");
        send_byte("T");send_byte("C");send_byte("F");
        if(threshold!=0 || run_requested || quality!=2) $fatal(1,"Threshold partial payload changed controls");
        send_byte(8'h0a);if(threshold!=8'hcf) $fatal(1,"Atomic threshold commit");
        send_byte("T");send_byte("f");send_byte("f");send_byte(8'h0a);
        if(threshold!=255 || run_requested) $fatal(1,"Lowercase threshold/full range");
        send_byte("A");send_byte("1");
        if(adaptive || run_requested) $fatal(1,"Partial adaptive command committed");
        send_byte(8'h0a);if(!adaptive) $fatal(1,"Adaptive enable");
        send_byte("A");send_byte("S");send_byte("C");send_byte(8'h0a);
        if(!adaptive || run_requested) $fatal(1,"Malformed adaptive bytes became legacy controls");
        send_byte("A");send_byte("0");send_byte(8'h0a);
        if(adaptive) $fatal(1,"Adaptive disable");
        send_byte("T");send_byte("1");send_byte("2");send_byte("S");send_byte("C");
        send_byte("L");send_byte("1");send_byte(8'h0a);
        if(threshold!=255 || run_requested || quality!=2 || starts!=1) $fatal(1,"Malformed payload leaked legacy commands");
        send_byte("T");send_byte("S");send_byte("L");send_byte(8'h0a);
        if(threshold!=255 || starts!=1) $fatal(1,"Malformed first digit changed state");
        send_byte("T");send_byte("0");press(1);
        if(!run_requested || threshold!=255) $fatal(1,"KEY0 blocked by threshold parser");
        send_byte("0");send_byte(8'h0a);
        if(threshold!=0) $fatal(1,"Zero threshold baseline");
        send_byte("T");send_byte("A");tick(55);
        send_byte("2");if(quality!=1 || threshold!=0) $fatal(1,"Timed-out parser did not recover");
        send_byte("T");send_byte("L");tick(55);
        send_byte("S");if(run_requested) $fatal(1,"Malformed parser timeout did not recover");
        send_byte("T");send_byte("0");send_byte("4");send_byte(8'h0a);
        if(threshold!=4) $fatal(1,"Parser failed after malformed/timeout recovery");
        if(denoise!=0 || disabled_threshold!=0 || disabled_adaptive) $fatal(1,"Removed interframe controls remained active");
        send_byte("N");send_byte("C");send_byte("F");
        if(denoise!=0 || nr_run!=run_requested) $fatal(1,"Partial denoise command leaked START");
        send_byte(8'h0a);if(denoise!=207 || disabled_denoise!=0) $fatal(1,"Atomic/capability-gated denoise commit");
        send_byte("N");send_byte("f");send_byte("f");send_byte(8'h0a);
        if(denoise!=255 || nr_run!=run_requested || nr_quality!=quality) $fatal(1,"Denoise full range changed legacy controls");
        send_byte("N");send_byte("S");send_byte("C");send_byte("L");send_byte(8'h0a);
        if(denoise!=255 || nr_run!=run_requested || starts!=1) $fatal(1,"Malformed denoise leaked controls");
        send_byte("N");send_byte("0");press(1);
        if(!nr_run || nr_run!=run_requested) $fatal(1,"KEY0 blocked by denoise parser");
        send_byte("0");send_byte(8'h0a);if(denoise!=0) $fatal(1,"Denoise off");
        send_byte("N");send_byte("A");tick(55);send_byte("S");
        if(nr_run || run_requested || denoise!=0) $fatal(1,"Denoise timeout recovery");
        if(pp_mode!=0 || binary_threshold!=128 || edge_threshold!=32) $fatal(1,"Preprocessing defaults");
        send_byte("B");send_byte("C");send_byte("F");
        if(binary_threshold!=128 || nr_run) $fatal(1,"Partial binary command/START isolation");
        send_byte(8'h0a);if(binary_threshold!=207) $fatal(1,"Atomic binary commit");
        send_byte("E");send_byte("f");send_byte("f");send_byte(8'h0a);
        if(edge_threshold!=255) $fatal(1,"Edge threshold full range");
        send_byte("M");send_byte("0");send_byte("3");send_byte(8'h0a);
        if(pp_mode!=3) $fatal(1,"Sobel mode");
        send_byte("M");send_byte("0");send_byte("4");send_byte(8'h0a);
        if(pp_mode!=3) $fatal(1,"Invalid mode accepted");
        send_byte("E");send_byte("S");send_byte("C");send_byte("L");send_byte(8'h0a);
        if(edge_threshold!=255 || nr_run || starts!=1) $fatal(1,"Malformed preprocessing leaked controls");
        send_byte("M");send_byte("0");press(1);
        if(!nr_run) $fatal(1,"Preprocessing parser blocked KEY0");
        send_byte("1");send_byte(8'h0a);if(pp_mode!=1) $fatal(1,"Gray mode");
        send_byte("M");send_byte("0");send_byte("2");send_byte(8'h0a);
        if(pp_mode!=2) $fatal(1,"Binary mode");
        send_byte("B");send_byte("0");send_byte("0");send_byte(8'h0a);
        send_byte("E");send_byte("0");send_byte("0");send_byte(8'h0a);
        if(binary_threshold!=0 || edge_threshold!=0) $fatal(1,"Threshold zero");
        send_byte("M");send_byte("0");tick(55);send_byte("S");
        if(nr_run || pp_mode!=2) $fatal(1,"Mode timeout recovery");
        send_byte("M");send_byte("0");send_byte("0");send_byte(8'h0a);
        if(pp_mode!=0 || disabled_mode!=0 || disabled_binary!=128 || disabled_edge!=32) $fatal(1,"Color/capability gating");
        marker=$fopen("BUTTON_DEBOUNCE_PASS.txt","w");
        $fdisplay(marker,"bounce rejection, held-key single event, four keys, LEDs, STOP priority, USB compatibility, legacy threshold isolation, atomic denoise/full range/off, removed interframe controls, malformed payload isolation, parser timeout and live keys passed");
        $fclose(marker);$finish;
    end
    initial begin #30000;$fatal(1,"Button watchdog");end
endmodule
