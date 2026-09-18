// Compatibility interface for the initial grayscale front-end project.
// The full JPEG core uses raster_to_mcu422 directly, at two samples/cycle.
module raster_to_block8x8 #(
    parameter MAX_WIDTH = 1920,
    RAM_ADDR_WIDTH = 14
) (
    input clk,
    input rst_n,
    input [15:0] cfg_width, cfg_height,
    input [7:0] s_data,
    input s_valid,
    output s_ready,
    input s_sof, s_eol, s_eof,
    output [7:0] m_data,
    output m_valid,
    input m_ready,
    output m_block_start, m_block_end, m_frame_start, m_frame_end,
    output protocol_error
);
    wire [15:0] pair_data;
    wire pair_valid, pair_ready;
    wire [4:0] pair_index;
    wire pair_fs, pair_fe;
    reg upper;
    assign pair_ready = upper && m_ready;
    assign m_data = upper ? pair_data[15:8] : pair_data[7:0];
    assign m_valid = pair_valid;
    assign m_block_start = (pair_index == 0) && !upper;
    assign m_block_end = (pair_index == 31) && upper;
    assign m_frame_start = pair_fs && !upper;
    assign m_frame_end = pair_fe && upper;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) upper <= 0;
        else if (m_valid && m_ready) upper <= !upper;
    end
    raster_to_mcu422 #(
        .MAX_WIDTH(MAX_WIDTH)
    ) core (
        .clk            (clk),
        .rst_n          (rst_n),
        .cfg_width      (cfg_width),
        .cfg_height     (cfg_height),
        .cfg_gray       (1'b1),
        .s_data         ({8'd0, s_data}),
        .s_valid        (s_valid),
        .s_ready        (s_ready),
        .s_sof          (s_sof),
        .s_eol          (s_eol),
        .s_eof          (s_eof),
        .m_data         (pair_data),
        .m_valid        (pair_valid),
        .m_ready        (pair_ready),
        .m_component    (),
        .m_pair         (pair_index),
        .m_frame_start  (pair_fs),
        .m_frame_end    (pair_fe),
        .protocol_error (protocol_error),
        .input_frame_end()
    );
endmodule
