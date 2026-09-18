`timescale 1ns / 1ps
module tb_netlist;
    tb_jpeg_encoder #(
        .WRAPPER      (1),
        .QUICK        (2),
        .INJECT_ERRORS(1)
    ) test ();
endmodule
