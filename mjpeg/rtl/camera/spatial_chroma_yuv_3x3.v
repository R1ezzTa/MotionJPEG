`timescale 1ns/1ps
// Smooth only Cb/Cr with 1-2-1 weights. Neighbours are selected by the
// robust Y guide, never by a noisy chroma centre. Y passes byte-exact.
module spatial_chroma_yuv_3x3 #(parameter WIDTH=1920,HEIGHT=1080)(
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
    function near;
        input [7:0] value,centre,limit;reg [8:0] lower,upper;
        begin lower={1'b0,centre}-{1'b0,limit};upper={1'b0,centre}+{1'b0,limit};
            near=(lower[8] || value>=lower[7:0]) && (upper[8] || value<=upper[7:0]);end
    endfunction
    wire [23:0] centre=window[4*24+:24];
    reg [23:0] selected[0:8];
    genvar item;
    generate for(item=0;item<9;item=item+1) begin: selection
        wire [23:0] candidate=window[item*24+:24];
        always @(posedge clk) if(ce)
            selected[item]<=(strength!=0 && near(candidate[23:16],centre[23:16],strength))?candidate:centre;
    end endgenerate
    reg selected_valid,selected_sof,selected_eol,selected_eof,selected_odd;
    reg rows_valid,rows_sof,rows_eol,rows_eof,rows_odd;
    reg [7:0] selected_y,rows_y,result_y,selected_strength,rows_strength;
    assign m_data[23:16]=result_y;
    always @(posedge clk) if(ce) begin selected_y<=centre[23:16];rows_y<=selected_y;result_y<=rows_y;end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            selected_valid<=0;rows_valid<=0;m_valid<=0;
            selected_sof<=0;selected_eol<=0;selected_eof<=0;selected_odd<=0;
            rows_sof<=0;rows_eol<=0;rows_eof<=0;rows_odd<=0;
            selected_strength<=0;rows_strength<=0;m_strength<=0;m_sof<=0;m_eol<=0;m_eof<=0;m_odd<=0;
        end else if(abort) begin
            selected_valid<=0;rows_valid<=0;m_valid<=0;m_sof<=0;m_eol<=0;m_eof<=0;m_odd<=0;
        end else if(ce) begin
            selected_valid<=valid;selected_sof<=sof;selected_eol<=eol;selected_eof<=eof;selected_odd<=odd;
            rows_valid<=selected_valid;rows_sof<=selected_sof;rows_eol<=selected_eol;rows_eof<=selected_eof;rows_odd<=selected_odd;
            m_valid<=rows_valid;m_sof<=rows_sof;m_eol<=rows_eol;m_eof<=rows_eof;m_odd<=rows_odd;
            selected_strength<=strength;rows_strength<=selected_strength;m_strength<=rows_strength;
        end
    end
    genvar plane;
    generate for(plane=0;plane<2;plane=plane+1) begin: channels
        reg [9:0] top_row,bottom_row;
        reg [10:0] middle_row;
        reg [7:0] result;
        wire [11:0] total={2'd0,top_row}+{1'b0,middle_row}+{2'd0,bottom_row}+12'd8;
        always @(posedge clk) if(ce) begin
            top_row<={2'd0,selected[0][plane*8+:8]}+{1'b0,selected[1][plane*8+:8],1'b0}+{2'd0,selected[2][plane*8+:8]};
            middle_row<={1'b0,selected[3][plane*8+:8],1'b0}+{1'b0,selected[4][plane*8+:8],2'b0}+{1'b0,selected[5][plane*8+:8],1'b0};
            bottom_row<={2'd0,selected[6][plane*8+:8]}+{1'b0,selected[7][plane*8+:8],1'b0}+{2'd0,selected[8][plane*8+:8]};
            result<=total[11:4];
        end
        assign m_data[plane*8+:8]=result;
    end endgenerate
endmodule
