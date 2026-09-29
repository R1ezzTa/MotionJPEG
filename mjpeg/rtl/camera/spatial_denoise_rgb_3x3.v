`timescale 1ns/1ps
// Current-frame RGB sigma filter: Gaussian 1-2-1 weights, reflected borders.
// A neighbour contributes only if every channel differs from the centre by
// at most the frame-latched strength; otherwise substitute the centre.
// Strength 0 is byte-exact bypass through the same line-buffer pipeline.
// No previous-frame storage, DDR transactions or temporal blending.
module spatial_denoise_rgb_3x3 #(parameter WIDTH=1920,HEIGHT=1080)(
    input clk,rst_n,abort,input [7:0] cfg_strength,
    input [23:0] s_data,input s_valid,output s_ready,
    input s_sof,s_eol,s_eof,
    output reg [23:0] m_data,output reg m_valid,input m_ready,
    output reg m_sof,m_eol,m_eof,m_odd
);
    (* ram_style="block" *) reg [23:0] even_line[0:WIDTH-1];
    (* ram_style="block" *) reg [23:0] odd_line[0:WIDTH-1];
    localparam ACTIVE=0,FINISH=1,BOTTOM=2,DONE=3;
    reg [1:0] mode;
    reg [15:0] in_x,in_y,bottom_x;
    reg line_wait,right_pending;
    reg [7:0] frame_strength;
    wire ce=!m_valid || m_ready;
    assign s_ready=rst_n && !abort && ce && mode==ACTIVE && !line_wait;
    wire real_token=s_valid && s_ready;
    wire bottom_token=ce && mode==BOTTOM && !line_wait;
    wire token=real_token || bottom_token;
    wire [15:0] token_x=bottom_token?bottom_x:in_x;
    wire [15:0] token_y=bottom_token?HEIGHT:in_y;
    reg a_valid;
    reg [15:0] a_x,a_y;
    reg [23:0] even_read,odd_read,a_bottom;
    wire [23:0] a_old=a_y[0]?odd_read:even_read;
    wire [23:0] a_mid=a_y[0]?even_read:odd_read;
    // Read-before-write; line RAM has no reset, preserving BRAM inference.
    always @(posedge clk) if(ce && token) begin
        even_read<=even_line[token_x];odd_read<=odd_line[token_x];
        if(!token_y[0]) begin
            if(real_token) even_line[token_x]<=s_data;
        end else begin
            if(real_token) odd_line[token_x]<=s_data;
        end
        a_bottom<=s_data;
    end
    wire [23:0] top=(a_y==1)?a_bottom:a_old;
    wire [23:0] bot=(a_y==HEIGHT)?a_old:a_bottom;
    reg [23:0] tl,tc,ml,mc,bl,bc;
    reg [15:0] center_x,center_y;
    wire [23:0] tr=right_pending?tl:top;
    wire [23:0] mr=right_pending?ml:a_mid;
    wire [23:0] br=right_pending?bl:bot;
    wire [23:0] lt=(center_x==0)?tr:tl;
    wire [23:0] lm=(center_x==0)?mr:ml;
    wire [23:0] lb=(center_x==0)?br:bl;
    function near;
        input [7:0] value,centre,strength;
        reg [8:0] lower,upper;
        begin
            // Shared centre bounds avoid a compare/subtract/absolute-value
            // chain for every neighbour. Bit 8 means a negative lower bound
            // or an upper bound above 255; no wraparound is used as a limit.
            lower={1'b0,centre}-{1'b0,strength};
            upper={1'b0,centre}+{1'b0,strength};
            near=(lower[8] || value>=lower[7:0]) && (upper[8] || value<=upper[7:0]);
        end
    endfunction
    function [23:0] neighbour;
        input [23:0] candidate,centre;
        input [7:0] strength;
        begin
            if(strength!=0 && near(candidate[23:16],centre[23:16],strength) &&
                near(candidate[15:8],centre[15:8],strength) &&
                near(candidate[7:0],centre[7:0],strength)) neighbour=candidate;
            else neighbour=centre;
        end
    endfunction
    wire [23:0] n00=neighbour(lt,mc,frame_strength),n01=neighbour(tc,mc,frame_strength);
    wire [23:0] n02=neighbour(tr,mc,frame_strength),n10=neighbour(lm,mc,frame_strength);
    wire [23:0] n12=neighbour(mr,mc,frame_strength),n20=neighbour(lb,mc,frame_strength);
    wire [23:0] n21=neighbour(bc,mc,frame_strength),n22=neighbour(br,mc,frame_strength);
    wire emit=right_pending || (a_valid && a_y!=0 && a_x!=0);
    reg rows_valid,rows_sof,rows_eol,rows_eof,rows_odd;
    wire emit_eol=right_pending;
    wire emit_sof=center_x==0 && center_y==0;
    wire emit_eof=right_pending && center_y==HEIGHT-1;
    reg [23:0] selected00,selected01,selected02,selected10,selected11,selected12,selected20,selected21,selected22;
    reg selected_valid,selected_sof,selected_eol,selected_eof,selected_odd;
    // Separate neighbour selection from accumulation. Every stage advances
    // under the same output credit, including all coordinate/valid markers.
    always @(posedge clk) if(ce) begin
        selected00<=n00;selected01<=n01;selected02<=n02;
        selected10<=n10;selected11<=mc;selected12<=n12;
        selected20<=n20;selected21<=n21;selected22<=n22;
    end
    genvar channel;
    generate for(channel=0;channel<3;channel=channel+1) begin: channels
        reg [9:0] top_row,bottom_row;
        reg [10:0] middle_row;
        wire [11:0] total={2'd0,top_row}+{1'b0,middle_row}+{2'd0,bottom_row}+12'd8;
        always @(posedge clk) if(ce) begin
            top_row<={2'd0,selected00[channel*8+:8]}+{1'd0,selected01[channel*8+:8],1'b0}+{2'd0,selected02[channel*8+:8]};
            middle_row<={2'd0,selected10[channel*8+:8],1'b0}+{1'd0,selected11[channel*8+:8],2'b0}+{2'd0,selected12[channel*8+:8],1'b0};
            bottom_row<={2'd0,selected20[channel*8+:8]}+{1'd0,selected21[channel*8+:8],1'b0}+{2'd0,selected22[channel*8+:8]};
        end
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) m_data[channel*8+:8]<=0;
            else if(abort) m_data[channel*8+:8]<=0;
            else if(ce) m_data[channel*8+:8]<=total[11:4];
        end
    end endgenerate
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            mode<=ACTIVE;in_x<=0;in_y<=0;bottom_x<=0;frame_strength<=0;
            a_valid<=0;a_x<=0;a_y<=0;line_wait<=0;right_pending<=0;
            tl<=0;tc<=0;ml<=0;mc<=0;bl<=0;bc<=0;center_x<=0;center_y<=0;
            rows_valid<=0;rows_sof<=0;rows_eol<=0;rows_eof<=0;rows_odd<=0;
            selected_valid<=0;selected_sof<=0;selected_eol<=0;selected_eof<=0;selected_odd<=0;
            m_valid<=0;m_sof<=0;m_eol<=0;m_eof<=0;m_odd<=0;
        end else if(abort) begin
            mode<=ACTIVE;in_x<=0;in_y<=0;bottom_x<=0;
            a_valid<=0;line_wait<=0;right_pending<=0;rows_valid<=0;selected_valid<=0;
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
                if(a_y==0) begin
                    if(a_x==WIDTH-1) line_wait<=0;
                end else if(a_x==0) begin
                    tl<=top;tc<=top;ml<=a_mid;mc<=a_mid;bl<=bot;bc<=bot;
                    center_x<=0;center_y<=a_y-1'b1;
                end else begin
                    tl<=tc;tc<=top;ml<=mc;mc<=a_mid;bl<=bc;bc<=bot;
                    center_x<=center_x+1'b1;
                    if(a_x==WIDTH-1) right_pending<=1;
                end
            end
            selected_valid<=emit;selected_sof<=emit_sof;selected_eol<=emit_eol;selected_eof<=emit_eof;selected_odd<=center_x[0];
            rows_valid<=selected_valid;rows_sof<=selected_sof;rows_eol<=selected_eol;rows_eof<=selected_eof;rows_odd<=selected_odd;
            m_valid<=rows_valid;m_sof<=rows_sof;m_eol<=rows_eol;m_eof<=rows_eof;m_odd<=rows_odd;
        end
    end
endmodule
