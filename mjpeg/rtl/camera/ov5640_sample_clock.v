`timescale 1ns/1ps
// 75MHz source-synchronous DVP. 1:1 MMCM with a BUFG feedback loop
// deskews the clock distribution. Sample the previous sensor byte just before
// the next falling launch (-30deg), avoiding fabric input hold-delay chains.
// Sensor clocks are finalized before reset release. Capture remains reset
// until LOCKED is synchronized in core_clk by the physical top.
module ov5640_sample_clock(
    input pclk,input reset,output sample_clock,output locked
);
    wire feedback_raw,feedback,clock_raw;
    MMCME2_BASE #(.BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(13.333333),.DIVCLK_DIVIDE(1),
        // 900MHz VCO leaves margin to both MMCM limits. Divide 12 permits
        // exact -30deg coarse phase (45/12 = 3.75deg per phase step).
        .CLKFBOUT_MULT_F(12.0),.CLKFBOUT_PHASE(0.0),
        .CLKOUT0_DIVIDE_F(12.0),.CLKOUT0_DUTY_CYCLE(0.5),.CLKOUT0_PHASE(-30.0),
        .STARTUP_WAIT("FALSE")) camera_mmcm(
        .CLKIN1(pclk),.CLKFBIN(feedback),.RST(reset),.PWRDWN(1'b0),
        .CLKFBOUT(feedback_raw),.CLKFBOUTB(),.CLKOUT0(clock_raw),.CLKOUT0B(),
        .CLKOUT1(),.CLKOUT1B(),.CLKOUT2(),.CLKOUT2B(),.CLKOUT3(),.CLKOUT3B(),
        .CLKOUT4(),.CLKOUT5(),.CLKOUT6(),.LOCKED(locked));
    BUFG feedback_buffer(.I(feedback_raw),.O(feedback));
    BUFG sample_buffer(.I(clock_raw),.O(sample_clock));
endmodule
