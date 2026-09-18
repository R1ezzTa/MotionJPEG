`timescale 1ns / 1ps
// Simulation starts after FPGA configuration. Supply the public global signals
// required by Anlogic's plaintext ERAM functional model (no encrypted model).
module PH1_PHY_GSR;
    reg usr_gsrn_en = 0;
    reg done_gwe = 0;
    reg gsr = 1;
    reg gsrn = 0;
    initial begin
        #20;
        done_gwe = 1;
        gsr = 0;
        gsrn = 1;
    end
endmodule
