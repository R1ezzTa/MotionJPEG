`timescale 1ns/1ps
// Independent-frame preprocessing. No previous frame, DDR reference or motion.
// YUV422 byte order: [15:8] alternating Cb/Cr, [7:0] Y.
module yuv422_preprocess #(parameter WIDTH=1920,HEIGHT=1080)(
    input clk,rst_n,abort,input [1:0] cfg_mode,
    input [7:0] cfg_binary_threshold,cfg_edge_threshold,
    input [15:0] s_data,input s_valid,output s_ready,
    input s_sof,s_eol,s_eof,
    output reg [15:0] m_data,output reg m_valid,input m_ready,
    output reg m_sof,m_eol,m_eof,
    output reg [1:0] active_mode,
    output reg [7:0] active_binary_threshold,active_edge_threshold,
    output reg [31:0] frames_started
);
    wire [143:0] win;
    wire [17:0] config_word;
    wire win_valid,win_sof,win_eol,win_eof;
    wire ce=!m_valid || m_ready;
    spatial_window_3x3 #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.DATA_WIDTH(16),.CONFIG_WIDTH(18)) window(
        .clk(clk),.rst_n(rst_n),.abort(abort),
        .cfg_strength({cfg_mode,cfg_edge_threshold,cfg_binary_threshold}),
        .s_data(s_data),.s_valid(s_valid),.s_ready(s_ready),
        .s_sof(s_sof),.s_eol(s_eol),.s_eof(s_eof),
        .m_window(win),.m_strength(config_word),.m_valid(win_valid),.m_ready(ce),
        .m_sof(win_sof),.m_eol(win_eol),.m_eof(win_eof),.m_odd());
    // Four pair differences run in parallel. Shared diagonal terms feed both
    // gradients; signed extension precedes the x2 shifts. Five arithmetic
    // stages accept one window/cycle, with common clock-enable under stalls.
    wire signed [8:0] tl=$signed({1'b0,win[7:0]});
    wire signed [8:0] tc=$signed({1'b0,win[23:16]});
    wire signed [8:0] tr=$signed({1'b0,win[39:32]});
    wire signed [8:0] ml=$signed({1'b0,win[55:48]});
    wire signed [8:0] mr=$signed({1'b0,win[87:80]});
    wire signed [8:0] bl=$signed({1'b0,win[103:96]});
    wire signed [8:0] bc=$signed({1'b0,win[119:112]});
    wire signed [8:0] br=$signed({1'b0,win[135:128]});
    reg signed [8:0] diagonal_a,diagonal_b,middle_x,middle_y;
    wire signed [10:0] da={{2{diagonal_a[8]}},diagonal_a};
    wire signed [10:0] db={{2{diagonal_b[8]}},diagonal_b};
    wire signed [10:0] mx={{2{middle_x[8]}},middle_x};
    wire signed [10:0] my={{2{middle_y[8]}},middle_y};
    reg signed [10:0] gx,gy;
    reg [10:0] ax,ay,magnitude;
    reg [15:0] center_pipe[0:3];
    reg [17:0] config_pipe[0:4];
    reg [3:0] valid_pipe,sof_pipe,eol_pipe,eof_pipe;
    integer stage;
    wire [8:0] normalized=magnitude[10:2];
    wire [7:0] edge_strength=normalized>255?8'd255:normalized[7:0];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            diagonal_a<=0;diagonal_b<=0;middle_x<=0;middle_y<=0;
            gx<=0;gy<=0;ax<=0;ay<=0;magnitude<=0;
            for(stage=0;stage<4;stage=stage+1) center_pipe[stage]<=0;
            for(stage=0;stage<5;stage=stage+1) config_pipe[stage]<=0;
            valid_pipe<=0;sof_pipe<=0;eol_pipe<=0;eof_pipe<=0;
            m_data<=0;m_valid<=0;m_sof<=0;m_eol<=0;m_eof<=0;
            active_mode<=0;active_binary_threshold<=128;active_edge_threshold<=32;frames_started<=0;
        end else if(abort) begin
            valid_pipe<=0;m_valid<=0;m_sof<=0;m_eol<=0;m_eof<=0;
        end else begin
            if(m_valid && m_ready && m_sof) begin
                active_mode<=config_pipe[4][17:16];
                active_edge_threshold<=config_pipe[4][15:8];
                active_binary_threshold<=config_pipe[4][7:0];
                frames_started<=frames_started+1'b1;
            end
            if(ce) begin
                diagonal_a<=br-tl;diagonal_b<=tr-bl;
                middle_x<=mr-ml;middle_y<=bc-tc;
                gx<=da+db+(mx<<<1);
                gy<=da-db+(my<<<1);
                ax<=gx[10]?-gx:gx;
                ay<=gy[10]?-gy:gy;
                magnitude<=ax+ay+11'd2;
                center_pipe[0]<=win[79:64];
                for(stage=1;stage<4;stage=stage+1) center_pipe[stage]<=center_pipe[stage-1];
                config_pipe[0]<=config_word;
                for(stage=1;stage<5;stage=stage+1) config_pipe[stage]<=config_pipe[stage-1];
                valid_pipe<={valid_pipe[2:0],win_valid};m_valid<=valid_pipe[3];
                sof_pipe<={sof_pipe[2:0],win_sof};m_sof<=sof_pipe[3];
                eol_pipe<={eol_pipe[2:0],win_eol};m_eol<=eol_pipe[3];
                eof_pipe<={eof_pipe[2:0],win_eof};m_eof<=eof_pipe[3];
                case(config_pipe[3][17:16])
                    0:m_data<=center_pipe[3];
                    1:m_data<={8'd128,center_pipe[3][7:0]};
                    2:m_data<={8'd128,center_pipe[3][7:0]>=config_pipe[3][7:0]?8'd255:8'd0};
                    // Preserve edge magnitude instead of amplifying every
                    // weak/noisy edge to a full-contrast white pixel.
                    3:m_data<={8'd128,edge_strength>=config_pipe[3][15:8]?edge_strength:8'd0};
                endcase
            end
        end
    end
endmodule
