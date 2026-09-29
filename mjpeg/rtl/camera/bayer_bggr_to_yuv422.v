`timescale 1ns/1ps
// One input byte/pixel. Two line RAMs, reflected borders, bilinear Bayer
// demosaic and full-range JPEG YCbCr. Entire pipeline holds under backpressure.
// The first output is delayed one row + one column; a synthetic final row
// flushes the bottom border. No full-frame buffer and no sensor JPEG path.
// BAYER_PATTERN: 0 BGGR (legacy default), 1 GRBG, 2 GBRG, 3 RGGB.
// Profile 5 uses BGGR after aligning its ISP vflip setting (3820=42).
module bayer_bggr_to_yuv422 #(parameter WIDTH=1920,HEIGHT=1080,BAYER_PATTERN=0,DENOISE_ENABLE=0)(
    input clk,input rst_n,input abort,
    input [7:0] cfg_denoise_strength,
    input [7:0] s_data,input s_valid,output s_ready,
    input s_sof,input s_eol,input s_eof,
    output reg [15:0] m_data,output reg m_valid,input m_ready,
    output reg m_sof,output reg m_eol,output reg m_eof
);
    (* ram_style="block" *) reg [7:0] even_line[0:WIDTH-1];
    (* ram_style="block" *) reg [7:0] odd_line[0:WIDTH-1];
    localparam ACTIVE=0,FINISH=1,BOTTOM=2,DONE=3;
    reg [1:0] mode;
    reg [15:0] in_x,in_y,bottom_x;
    reg line_wait,right_pending;
    reg [7:0] rgb_r,rgb_g,rgb_b;
    reg rgb_valid,rgb_sof,rgb_eol,rgb_eof,rgb_odd;
    wire filtered_ready;
    wire ce=!rgb_valid || filtered_ready;
    assign s_ready=rst_n && !abort && ce && mode==ACTIVE && !line_wait;
    wire real_token=s_valid && s_ready;
    wire bottom_token=ce && mode==BOTTOM && !line_wait;
    wire token=real_token || bottom_token;
    wire [15:0] token_x=bottom_token?bottom_x:in_x;
    wire [15:0] token_y=bottom_token?HEIGHT:in_y;
    reg a_valid;
    reg [15:0] a_x,a_y;
    reg [7:0] even_read,odd_read,a_bottom;
    wire [7:0] a_old=a_y[0]?odd_read:even_read;
    wire [7:0] a_mid=a_y[0]?even_read:odd_read;
    // Read-before-write supplies y-2 from the bank overwritten by row y.
    // RAM ports and addresses are deliberately free of asynchronous resets.
    always @(posedge clk) if(ce && token) begin
        even_read<=even_line[token_x];odd_read<=odd_line[token_x];
        if(!token_y[0]) begin
            if(real_token) even_line[token_x]<=s_data;
        end else begin
            if(real_token) odd_line[token_x]<=s_data;
        end
        a_bottom<=s_data;
    end
    wire [7:0] top=(a_y==1)?a_bottom:a_old;
    wire [7:0] bot=(a_y==HEIGHT)?a_old:a_bottom;
    reg [7:0] tl,tc,ml,mc,bl,bc;
    reg [15:0] center_x,center_y;
    wire [7:0] tr=right_pending?tl:top;
    wire [7:0] mr=right_pending?ml:a_mid;
    wire [7:0] br=right_pending?bl:bot;
    wire [7:0] lt=(center_x==0)?tr:tl;
    wire [7:0] lm=(center_x==0)?mr:ml;
    wire [7:0] lb=(center_x==0)?br:bl;
    wire [9:0] cross_sum={2'd0,tc}+{2'd0,lm}+{2'd0,mr}+{2'd0,bc};
    wire [9:0] diagonal_sum={2'd0,lt}+{2'd0,tr}+{2'd0,lb}+{2'd0,br};
    wire [8:0] horizontal_sum={1'b0,lm}+{1'b0,mr};
    wire [8:0] vertical_sum={1'b0,tc}+{1'b0,bc};
    reg [7:0] r,g,b;
    always @* begin
        case({center_y[0] ^ (BAYER_PATTERN==1 || BAYER_PATTERN==3),
              center_x[0] ^ (BAYER_PATTERN==2 || BAYER_PATTERN==3)})
            2'b00: begin b=mc;g=cross_sum[9:2];r=diagonal_sum[9:2];end
            2'b01: begin g=mc;b=horizontal_sum[8:1];r=vertical_sum[8:1];end
            2'b10: begin g=mc;r=horizontal_sum[8:1];b=vertical_sum[8:1];end
            2'b11: begin r=mc;g=cross_sum[9:2];b=diagonal_sum[9:2];end
        endcase
    end
    // Keep full Y/Cb/Cr until after denoising so neighbouring U and V samples
    // cannot be mixed by the alternating 4:2:2 byte layout.
    wire [23:0] filtered_data={rgb_r,rgb_g,rgb_b};
    wire filtered_valid=rgb_valid,filtered_sof=rgb_sof,filtered_eol=rgb_eol,filtered_eof=rgb_eof,filtered_odd=rgb_odd;
    reg [23:0] yuv_data;
    reg yuv_valid,yuv_sof,yuv_eol,yuv_eof,yuv_odd;
    wire yuv_ready;
    wire color_ce=!yuv_valid || yuv_ready;
    assign filtered_ready=color_ce;
    reg signed [18:0] y_sum,cb_sum,cr_sum;
    reg sum_valid,sum_sof,sum_eol,sum_eof,sum_odd;
    // Constant products are signed explicitly; Cb/Cr include +128 offset.
    always @(posedge clk) if(color_ce) begin
        y_sum<=19'sd77*$signed({1'b0,filtered_data[23:16]})+19'sd150*$signed({1'b0,filtered_data[15:8]})+19'sd29*$signed({1'b0,filtered_data[7:0]});
        cb_sum<=19'sd32768-19'sd43*$signed({1'b0,filtered_data[23:16]})-19'sd85*$signed({1'b0,filtered_data[15:8]})+19'sd128*$signed({1'b0,filtered_data[7:0]});
        cr_sum<=19'sd32768+19'sd128*$signed({1'b0,filtered_data[23:16]})-19'sd107*$signed({1'b0,filtered_data[15:8]})-19'sd21*$signed({1'b0,filtered_data[7:0]});
    end
    function [7:0] saturate;
        input signed [18:0] value;
        begin
            if(value<0) saturate=0;
            else if(value>19'sd65535) saturate=255;
            else saturate=value[15:8];
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            mode<=ACTIVE;in_x<=0;in_y<=0;bottom_x<=0;
            a_valid<=0;a_x<=0;a_y<=0;line_wait<=0;right_pending<=0;
            tl<=0;tc<=0;ml<=0;mc<=0;bl<=0;bc<=0;center_x<=0;center_y<=0;
            rgb_r<=0;rgb_g<=0;rgb_b<=0;
            rgb_valid<=0;rgb_sof<=0;rgb_eol<=0;rgb_eof<=0;rgb_odd<=0;
        end else if(abort) begin
            mode<=ACTIVE;in_x<=0;in_y<=0;bottom_x<=0;
            a_valid<=0;line_wait<=0;right_pending<=0;
            rgb_valid<=0;
        end else if(ce) begin
            a_valid<=token;
            if(token) begin
                a_x<=token_x;a_y<=token_y;
                if(token_x==WIDTH-1) line_wait<=1;
                if(real_token) begin
                    if(in_x==WIDTH-1) begin in_x<=0;in_y<=in_y+1'b1;end
                    else in_x<=in_x+1'b1;
                    if(s_eof) begin mode<=FINISH;bottom_x<=0;end
                end else begin
                    if(bottom_x==WIDTH-1) mode<=DONE;
                    else bottom_x<=bottom_x+1'b1;
                end
            end
            rgb_valid<=0;
            if(right_pending) begin
                rgb_r<=r;rgb_g<=g;rgb_b<=b;rgb_valid<=1;
                rgb_sof<=0;rgb_eol<=1;rgb_eof<=(center_y==HEIGHT-1);rgb_odd<=center_x[0];
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
                    rgb_r<=r;rgb_g<=g;rgb_b<=b;rgb_valid<=1;
                    rgb_sof<=(center_y==0 && center_x==0);
                    rgb_eol<=0;rgb_eof<=0;rgb_odd<=center_x[0];
                    tl<=tc;tc<=top;ml<=mc;mc<=a_mid;bl<=bc;bc<=bot;
                    center_x<=center_x+1'b1;
                    if(a_x==WIDTH-1) right_pending<=1;
                end
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            sum_valid<=0;sum_sof<=0;sum_eol<=0;sum_eof<=0;sum_odd<=0;
            yuv_data<=0;yuv_valid<=0;yuv_sof<=0;yuv_eol<=0;yuv_eof<=0;yuv_odd<=0;
        end else if(abort) begin
            sum_valid<=0;yuv_valid<=0;yuv_sof<=0;yuv_eol<=0;yuv_eof<=0;
        end else if(color_ce) begin
            sum_valid<=filtered_valid;sum_sof<=filtered_sof;sum_eol<=filtered_eol;sum_eof<=filtered_eof;sum_odd<=filtered_odd;
            yuv_valid<=sum_valid;yuv_sof<=sum_sof;yuv_eol<=sum_eol;yuv_eof<=sum_eof;yuv_odd<=sum_odd;
            yuv_data<={saturate(y_sum),saturate(cb_sum),saturate(cr_sum)};
        end
    end
    wire [23:0] processed_data;
    wire processed_valid,processed_sof,processed_eol,processed_eof,processed_odd;
    wire pack_ce=!m_valid || m_ready;
    generate if(DENOISE_ENABLE) begin: denoising
        spatial_denoise_yuv #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) filter(
            .clk(clk),.rst_n(rst_n),.abort(abort),.cfg_strength(cfg_denoise_strength),
            .s_data(yuv_data),.s_valid(yuv_valid),.s_ready(yuv_ready),.s_sof(yuv_sof),.s_eol(yuv_eol),.s_eof(yuv_eof),
            .m_data(processed_data),.m_valid(processed_valid),.m_ready(pack_ce),
            .m_sof(processed_sof),.m_eol(processed_eol),.m_eof(processed_eof),.m_odd(processed_odd));
    end else begin: unfiltered
        assign processed_data=yuv_data;assign processed_valid=yuv_valid;assign yuv_ready=pack_ce;
        assign processed_sof=yuv_sof;assign processed_eol=yuv_eol;assign processed_eof=yuv_eof;assign processed_odd=yuv_odd;
    end endgenerate
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin m_data<=0;m_valid<=0;m_sof<=0;m_eol<=0;m_eof<=0;end
        else if(abort) begin m_valid<=0;m_sof<=0;m_eol<=0;m_eof<=0;end
        else if(pack_ce) begin
            m_valid<=processed_valid;m_sof<=processed_sof;m_eol<=processed_eol;m_eof<=processed_eof;
            m_data<={processed_odd?processed_data[7:0]:processed_data[15:8],processed_data[23:16]};
        end
    end
endmodule
