`timescale 1ns / 1ps
module tb_protocol;
    tb_jpeg_encoder #(
        .QUICK        (1),
        .INJECT_ERRORS(1)
    ) test ();
endmodule
