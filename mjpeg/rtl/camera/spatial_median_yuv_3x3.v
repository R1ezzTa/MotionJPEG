`timescale 1ns/1ps
// Robust median of nine samples for Y/Cb/Cr. N=0 is exact bypass.
// Blend original and median using alpha=min(N,32)/32. N32 removes isolated
// outliers fully; changing N inside a frame cannot change its latched alpha.
module spatial_median_yuv_3x3 #(parameter WIDTH=1920,HEIGHT=1080)(
    input clk,rst_n,abort,input [7:0] cfg_strength,
    input [23:0] s_data,input s_valid,output s_ready,input s_sof,s_eol,s_eof,
    output [23:0] m_data,output reg [7:0] m_strength,
    output reg m_valid,input m_ready,output reg m_sof,m_eol,m_eof,m_odd
);
    wire [215:0] window;
    wire [7:0] strength;
    wire valid,sof,eol,eof,odd;
    wire ce=!m_valid || m_ready;
    spatial_window_3x3 #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) windows(
        .clk(clk),.rst_n(rst_n),.abort(abort),.cfg_strength(cfg_strength),
        .s_data(s_data),.s_valid(s_valid),.s_ready(s_ready),.s_sof(s_sof),.s_eol(s_eol),.s_eof(s_eof),
        .m_window(window),.m_strength(strength),.m_valid(valid),.m_ready(ce),
        .m_sof(sof),.m_eol(eol),.m_eof(eof),.m_odd(odd));
    function [7:0] low3;
        input [7:0] a,b,c;reg [7:0] ab;
        begin ab=a<b?a:b;low3=ab<c?ab:c;end
    endfunction
    function [7:0] high3;
        input [7:0] a,b,c;reg [7:0] ab;
        begin ab=a>b?a:b;high3=ab>c?ab:c;end
    endfunction
    function [7:0] middle3;
        input [7:0] a,b,c;reg [7:0] lo,hi;
        begin lo=a<b?a:b;hi=a<b?b:a;middle3=c<lo?lo:(c>hi?hi:c);end
    endfunction
    reg [4:0] valid_pipe,sof_pipe,eol_pipe,eof_pipe,odd_pipe;
    reg [7:0] strength0,strength1,strength2,strength3,strength4;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            valid_pipe<=0;sof_pipe<=0;eol_pipe<=0;eof_pipe<=0;odd_pipe<=0;
            strength0<=0;strength1<=0;strength2<=0;strength3<=0;strength4<=0;m_strength<=0;
            m_valid<=0;m_sof<=0;m_eol<=0;m_eof<=0;m_odd<=0;
        end else if(abort) begin
            valid_pipe<=0;m_valid<=0;m_sof<=0;m_eol<=0;m_eof<=0;m_odd<=0;
        end else if(ce) begin
            valid_pipe<={valid_pipe[3:0],valid};sof_pipe<={sof_pipe[3:0],sof};
            eol_pipe<={eol_pipe[3:0],eol};eof_pipe<={eof_pipe[3:0],eof};odd_pipe<={odd_pipe[3:0],odd};
            strength0<=strength;strength1<=strength0;strength2<=strength1;strength3<=strength2;strength4<=strength3;m_strength<=strength4;
            m_valid<=valid_pipe[4];m_sof<=sof_pipe[4];m_eol<=eol_pipe[4];m_eof<=eof_pipe[4];m_odd<=odd_pipe[4];
        end
    end
    genvar plane;
    generate for(plane=0;plane<3;plane=plane+1) begin: channels
        wire [7:0] p0=window[0*24+plane*8+:8],p1=window[1*24+plane*8+:8],p2=window[2*24+plane*8+:8];
        wire [7:0] p3=window[3*24+plane*8+:8],p4=window[4*24+plane*8+:8],p5=window[5*24+plane*8+:8];
        wire [7:0] p6=window[6*24+plane*8+:8],p7=window[7*24+plane*8+:8],p8=window[8*24+plane*8+:8];
        reg [7:0] lo0,lo1,lo2,mid0,mid1,mid2,hi0,hi1,hi2;
        reg [7:0] low_max,mid_mid,high_min,median,original0,original1,original2,original3;
        reg signed [8:0] difference;
        // Keep the three small multiply-adds in DSPs to preserve scarce LUTs.
        (* use_dsp="yes" *) reg signed [15:0] weighted;
        reg [7:0] result;
        wire [5:0] alpha=strength3>=32?6'd32:{1'b0,strength3[4:0]};
        always @(posedge clk) if(ce) begin
            lo0<=low3(p0,p1,p2);mid0<=middle3(p0,p1,p2);hi0<=high3(p0,p1,p2);
            lo1<=low3(p3,p4,p5);mid1<=middle3(p3,p4,p5);hi1<=high3(p3,p4,p5);
            lo2<=low3(p6,p7,p8);mid2<=middle3(p6,p7,p8);hi2<=high3(p6,p7,p8);
            low_max<=high3(lo0,lo1,lo2);mid_mid<=middle3(mid0,mid1,mid2);high_min<=low3(hi0,hi1,hi2);
            median<=middle3(low_max,mid_mid,high_min);
            original0<=p4;original1<=original0;original2<=original1;original3<=original2;
            // Exact algebraic factorization: one signed multiply per plane
            // instead of two. All three planes remain parallel, one pixel
            // per enabled cycle. A separate difference stage bounds timing.
            difference<=$signed({1'b0,median})-$signed({1'b0,original2});
            weighted<=$signed({3'b0,original3,5'b10000})+
                       difference*$signed({1'b0,alpha});
            result<=weighted[12:5];
        end
        assign m_data[plane*8+:8]=result;
    end endgenerate
endmodule
