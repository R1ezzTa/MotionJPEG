// Full-width rows exercise the RAM address padding/truncation used by 1080p.
module tb_mjpeg_wide;
    tb_mjpeg_common #(.BOARD(1), .WIDE(1)) test ();
endmodule
