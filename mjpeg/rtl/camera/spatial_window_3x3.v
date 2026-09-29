`timescale 1ns/1ps
// Current-frame, reflected 3x3 window. Frame configuration travels with it.
// Two synchronous read-before-write line banks; no frame or DDR history.
module spatial_window_3x3 #(parameter WIDTH=1920,HEIGHT=1080,DATA_WIDTH=24,CONFIG_WIDTH=8)(
    input clk,rst_n,abort,input [CONFIG_WIDTH-1:0] cfg_strength,
    input [DATA_WIDTH-1:0] s_data,input s_valid,output s_ready,
    input s_sof,s_eol,s_eof,
    output reg [9*DATA_WIDTH-1:0] m_window,output reg [CONFIG_WIDTH-1:0] m_strength,
    output reg m_valid,input m_ready,output reg m_sof,m_eol,m_eof,m_odd
);
    (* ram_style="block" *) reg [DATA_WIDTH-1:0] even_line[0:WIDTH-1];
    (* ram_style="block" *) reg [DATA_WIDTH-1:0] odd_line[0:WIDTH-1];
    localparam ACTIVE=0,FINISH=1,BOTTOM=2,DONE=3;
    reg [1:0] mode;
    reg [15:0] in_x,in_y,bottom_x,a_x,a_y,center_x,center_y;
    reg line_wait,right_pending,a_valid;
    reg [CONFIG_WIDTH-1:0] frame_strength;
    reg [DATA_WIDTH-1:0] even_read,odd_read,a_bottom,tl,tc,ml,mc,bl,bc;
    wire ce=!m_valid || m_ready;
    assign s_ready=rst_n && !abort && ce && mode==ACTIVE && !line_wait;
    wire real_token=s_valid && s_ready;
    wire bottom_token=ce && mode==BOTTOM && !line_wait;
    wire token=real_token || bottom_token;
    wire [15:0] token_x=bottom_token?bottom_x:in_x;
    wire [15:0] token_y=bottom_token?HEIGHT:in_y;
    wire [DATA_WIDTH-1:0] a_old=a_y[0]?odd_read:even_read;
    wire [DATA_WIDTH-1:0] a_mid=a_y[0]?even_read:odd_read;
    always @(posedge clk) if(ce && token) begin
        even_read<=even_line[token_x];odd_read<=odd_line[token_x];
        if(!token_y[0]) begin if(real_token) even_line[token_x]<=s_data;end
        else begin if(real_token) odd_line[token_x]<=s_data;end
        a_bottom<=s_data;
    end
    wire [DATA_WIDTH-1:0] top=(a_y==1)?a_bottom:a_old;
    wire [DATA_WIDTH-1:0] bot=(a_y==HEIGHT)?a_old:a_bottom;
    wire [DATA_WIDTH-1:0] tr=right_pending?tl:top;
    wire [DATA_WIDTH-1:0] mr=right_pending?ml:a_mid;
    wire [DATA_WIDTH-1:0] br=right_pending?bl:bot;
    wire [DATA_WIDTH-1:0] lt=(center_x==0)?tr:tl;
    wire [DATA_WIDTH-1:0] lm=(center_x==0)?mr:ml;
    wire [DATA_WIDTH-1:0] lb=(center_x==0)?br:bl;
    wire emit=right_pending || (a_valid && a_y!=0 && a_x!=0);
    always @(posedge clk) if(ce) m_window<={br,bc,lb,mr,mc,lm,tr,tc,lt};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            mode<=ACTIVE;in_x<=0;in_y<=0;bottom_x<=0;a_x<=0;a_y<=0;
            center_x<=0;center_y<=0;line_wait<=0;right_pending<=0;a_valid<=0;
            frame_strength<=0;m_strength<=0;
            tl<=0;tc<=0;ml<=0;mc<=0;bl<=0;bc<=0;
            m_valid<=0;m_sof<=0;m_eol<=0;m_eof<=0;m_odd<=0;
        end else if(abort) begin
            mode<=ACTIVE;in_x<=0;in_y<=0;bottom_x<=0;
            a_valid<=0;line_wait<=0;right_pending<=0;
            m_valid<=0;m_sof<=0;m_eol<=0;m_eof<=0;m_odd<=0;
        end else if(ce) begin
            a_valid<=token;
            if(token) begin
                a_x<=token_x;a_y<=token_y;
                if(token_x==WIDTH-1) line_wait<=1;
                if(real_token) begin
                    if(s_sof) frame_strength<=cfg_strength;
                    if(in_x==WIDTH-1) begin in_x<=0;in_y<=in_y+1'b1;end
                    else in_x<=in_x+1'b1;
                    if(s_eof) begin mode<=FINISH;bottom_x<=0;end
                end else begin
                    if(bottom_x==WIDTH-1) mode<=DONE;
                    else bottom_x<=bottom_x+1'b1;
                end
            end
            if(right_pending) begin
                right_pending<=0;line_wait<=0;
                if(mode==FINISH) mode<=BOTTOM;
                if(mode==DONE) begin mode<=ACTIVE;in_x<=0;in_y<=0;end
            end else if(a_valid) begin
                if(a_y==0) begin if(a_x==WIDTH-1) line_wait<=0;end
                else if(a_x==0) begin
                    tl<=top;tc<=top;ml<=a_mid;mc<=a_mid;bl<=bot;bc<=bot;
                    center_x<=0;center_y<=a_y-1'b1;
                end else begin
                    tl<=tc;tc<=top;ml<=mc;mc<=a_mid;bl<=bc;bc<=bot;
                    center_x<=center_x+1'b1;
                    if(a_x==WIDTH-1) right_pending<=1;
                end
            end
            m_valid<=emit;m_strength<=frame_strength;
            m_sof<=center_x==0 && center_y==0;
            m_eol<=right_pending;m_eof<=right_pending && center_y==HEIGHT-1;
            m_odd<=center_x[0];
        end
    end
endmodule
