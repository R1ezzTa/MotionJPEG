`timescale 1ns/1ps
module tb_jpeg_adaptive_ddr;
    tb_jpeg_threshold_ddr #(.FRAME_COUNT(20),.ADAPTIVE_TEST(1),.FRAME_STRIDE(4096),
        .INPUT_FILE("adaptive_input.mem"),.LENGTH_FILE("adaptive_lengths.mem"),.VALUE_FILE("adaptive_values.mem"),
        .MODE_FILE("adaptive_modes.mem"),.OUTPUT_PATTERN("adaptive_%0d.spj"),
        .PASS_FILE("ADAPTIVE_DDR_PASS.txt")) test();
endmodule
module tb_jpeg_adaptive_ddr_pressure;
    tb_jpeg_threshold_ddr #(.FRAME_COUNT(20),.ADAPTIVE_TEST(1),.PRESSURE_TEST(1),.FRAME_STRIDE(4096),
        .INPUT_FILE("adaptive_pressure_input.mem"),.LENGTH_FILE("adaptive_pressure_lengths.mem"),.VALUE_FILE("adaptive_pressure_values.mem"),
        .MODE_FILE("adaptive_pressure_modes.mem"),.OUTPUT_PATTERN("adaptive_pressure_%0d.spj"),
        .PASS_FILE("ADAPTIVE_DDR_PRESSURE_PASS.txt")) test();
endmodule
module tb_jpeg_adaptive_ddr_queue;
    tb_jpeg_threshold_ddr #(.FRAME_COUNT(20),.ADAPTIVE_TEST(1),.SOURCE_GAP(0),.FRAME_STRIDE(4096),
        .INPUT_FILE("adaptive_queue_input.mem"),.LENGTH_FILE("adaptive_queue_lengths.mem"),.VALUE_FILE("adaptive_queue_values.mem"),
        .MODE_FILE("adaptive_queue_modes.mem"),.OUTPUT_PATTERN("adaptive_queue_%0d.spj"),
        .PASS_FILE("ADAPTIVE_DDR_QUEUE_PASS.txt")) test();
endmodule
module tb_jpeg_adaptive_ddr_budget;
    tb_jpeg_threshold_ddr #(.FRAME_COUNT(20),.ADAPTIVE_TEST(1),.ADAPTIVE_BUDGET(8),.FRAME_STRIDE(4096),
        .INPUT_FILE("adaptive_budget_input.mem"),.LENGTH_FILE("adaptive_budget_lengths.mem"),.VALUE_FILE("adaptive_budget_values.mem"),
        .MODE_FILE("adaptive_budget_modes.mem"),.OUTPUT_PATTERN("adaptive_budget_%0d.spj"),
        .PASS_FILE("ADAPTIVE_DDR_BUDGET_PASS.txt")) test();
endmodule
module tb_jpeg_adaptive_ddr_full;
    tb_jpeg_threshold_ddr #(.FRAME_COUNT(8),.ADAPTIVE_TEST(1),.FRAME_STRIDE(262144),.MEM_SLOTS(4050),
        .WIDTH(1920),.HEIGHT(1080),.WATCHDOG(20000000),
        .INPUT_FILE("adaptive_full_input.mem"),.LENGTH_FILE("adaptive_full_lengths.mem"),
        .VALUE_FILE("adaptive_full_values.mem"),.MODE_FILE("adaptive_full_modes.mem"),
        .OUTPUT_PATTERN("adaptive_full_%0d.spj"),.PASS_FILE("ADAPTIVE_DDR_FULL_PASS.txt")) test();
endmodule
