`timescale 1ns/1ps
// Median impulse reduction followed by two Y-guided chroma Gaussian passes.
// Flat-region chroma support is 5x5; the median adds robust local estimation.
// Full YCbCr is filtered before 4:2:2 packing. No temporal/DDR reference.
module spatial_denoise_yuv #(parameter WIDTH=1920,HEIGHT=1080)(
    input clk,rst_n,abort,input [7:0] cfg_strength,
    input [23:0] s_data,input s_valid,output s_ready,input s_sof,s_eol,s_eof,
    output [23:0] m_data,output m_valid,input m_ready,output m_sof,m_eol,m_eof,m_odd
);
    wire [23:0] median_data,first_data;
    wire [7:0] median_strength,first_strength;
    wire median_valid,median_ready,median_sof,median_eol,median_eof,median_odd;
    wire first_valid,first_ready,first_sof,first_eol,first_eof,first_odd;
    spatial_median_yuv_3x3 #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) median_filter(
        .clk(clk),.rst_n(rst_n),.abort(abort),.cfg_strength(cfg_strength),
        .s_data(s_data),.s_valid(s_valid),.s_ready(s_ready),.s_sof(s_sof),.s_eol(s_eol),.s_eof(s_eof),
        .m_data(median_data),.m_strength(median_strength),.m_valid(median_valid),.m_ready(median_ready),
        .m_sof(median_sof),.m_eol(median_eol),.m_eof(median_eof),.m_odd(median_odd));
    spatial_chroma_yuv_3x3 #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) chroma_first(
        .clk(clk),.rst_n(rst_n),.abort(abort),.cfg_strength(median_strength),
        .s_data(median_data),.s_valid(median_valid),.s_ready(median_ready),
        .s_sof(median_sof),.s_eol(median_eol),.s_eof(median_eof),
        .m_data(first_data),.m_strength(first_strength),.m_valid(first_valid),.m_ready(first_ready),
        .m_sof(first_sof),.m_eol(first_eol),.m_eof(first_eof),.m_odd(first_odd));
    spatial_chroma_yuv_3x3 #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) chroma_second(
        .clk(clk),.rst_n(rst_n),.abort(abort),.cfg_strength(first_strength),
        .s_data(first_data),.s_valid(first_valid),.s_ready(first_ready),
        .s_sof(first_sof),.s_eol(first_eol),.s_eof(first_eof),
        .m_data(m_data),.m_strength(),.m_valid(m_valid),.m_ready(m_ready),
        .m_sof(m_sof),.m_eol(m_eol),.m_eof(m_eof),.m_odd(m_odd));
endmodule
