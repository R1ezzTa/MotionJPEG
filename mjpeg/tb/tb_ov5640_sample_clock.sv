`timescale 1ns/1ps
module tb_ov5640_sample_clock;
    localparam real PERIOD=1000.0/75.0;
    reg pclk=0,reset=1;
    always #(PERIOD/2) pclk=~pclk;
    wire sample_clock,locked;
    ov5640_sample_clock dut(.*);
    realtime reference_rise=0,last_edge=0,phase_delta;
    integer checked=0;
    always @(posedge pclk) reference_rise=$realtime;
    always @(negedge sample_clock) begin
        if(locked && !reset) begin
            phase_delta=$realtime-reference_rise;
            if(phase_delta<PERIOD*(5.0/12.0)-0.15 || phase_delta>PERIOD*(5.0/12.0)+0.15)
                $fatal(1,"wrong sample phase %0.3f expected %0.3f",phase_delta,PERIOD*(5.0/12.0));
            if(last_edge && ($realtime-last_edge<PERIOD-0.02 || $realtime-last_edge>PERIOD+0.02))
                $fatal(1,"clock period changed %0.3f",$realtime-last_edge);
            last_edge=$realtime;checked=checked+1;
        end else last_edge=0;
    end
    initial begin
        #500;reset=0;wait(locked);wait(checked>=64);
        reset=1;#200;
        if(locked) $fatal(1,"LOCKED remained set during reset");
        last_edge=0;reset=0;wait(locked);wait(checked>=128);
        $display("PASS real MMCM primitive: 75MHz 1:1, -30deg falling sample phase, reset/relock, 128 checked edges");
        $finish;
    end
    initial begin #200000;$fatal(1,"camera MMCM lock timeout");end
endmodule
