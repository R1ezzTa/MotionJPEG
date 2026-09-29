// Board oscillator 50MHz -> VCO 1000MHz -> encoding clock 100MHz.
// LOCKED drops on board reset or loss of the reference clock; consumers
// assert reset asynchronously and release it through local synchronizers.
module board_test_core_clock(
    input ref_clk,rst_n,output core_clk,output locked
);
    wire feedback_raw,feedback,core_raw;
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),.CLKIN1_PERIOD(20.0),
        .DIVCLK_DIVIDE(1),.CLKFBOUT_MULT_F(20.0),
        .CLKOUT0_DIVIDE_F(10.0),.CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE(0.0),.STARTUP_WAIT("FALSE")
    ) mmcm(
        .CLKIN1(ref_clk),.CLKFBIN(feedback),.CLKFBOUT(feedback_raw),
        .CLKOUT0(core_raw),.CLKOUT1(),.LOCKED(locked),.PWRDWN(1'b0),.RST(!rst_n)
    );
    BUFG feedback_buffer(.I(feedback_raw),.O(feedback));
    BUFG core_buffer(.I(core_raw),.O(core_clk));
endmodule
