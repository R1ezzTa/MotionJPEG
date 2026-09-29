`timescale 1ns/1ps
module tb_yuv422_preprocess #(parameter W=16,H=8,FRAMES=12);
    localparam N=W*H;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,abort=0;
    reg [1:0] cfg_mode=0;
    reg [7:0] cfg_binary_threshold=128,cfg_edge_threshold=32;
    reg [15:0] s_data=0;
    reg s_valid=0,s_sof=0,s_eol=0,s_eof=0;
    wire s_ready;
    wire [15:0] m_data;
    wire m_valid,m_sof,m_eol,m_eof;
    reg m_ready=0;
    wire [1:0] active_mode;
    wire [7:0] active_binary_threshold,active_edge_threshold;
    wire [31:0] frames_started;
    reg [15:0] source[0:FRAMES*N-1],golden[0:FRAMES*N-1];
    reg [17:0] configs[0:FRAMES-1];
    integer sent=0,got=0,frame=0,cycles=0;
    reg held=0;reg [18:0] held_word;
    yuv422_preprocess #(.WIDTH(W),.HEIGHT(H)) dut(.*);
    always @(posedge clk) if(rst_n && !abort) begin
        cycles=cycles+1;
        if(held && (!m_valid || {m_eof,m_eol,m_sof,m_data}!==held_word)) $fatal(1,"Output changed under stall");
        held=m_valid && !m_ready;held_word={m_eof,m_eol,m_sof,m_data};
        if(m_valid && m_ready) begin
            if(got>=N || m_data!==golden[frame*N+got])
                $fatal(1,"Preprocess mismatch frame=%0d pixel=%0d got=%04x expected=%04x",frame,got,m_data,golden[frame*N+got]);
            if(m_sof!=(got==0) || m_eol!=(got%W==W-1) || m_eof!=(got==N-1)) $fatal(1,"Marker mismatch at %0d",got);
            got=got+1;
        end
    end
    initial begin
        $readmemh("source.mem",source);$readmemh("golden.mem",golden);$readmemh("config.mem",configs);
        repeat(10) @(negedge clk);rst_n=1;
        // Aborted dirty line RAM must not leak into the next frame.
        for(sent=0;sent<W+3;sent=sent+1) begin
            s_valid=1;s_data=source[sent];s_sof=(sent==0);s_eol=(sent%W==W-1);s_eof=0;
            @(posedge clk);while(!s_ready) @(posedge clk);@(negedge clk);
        end
        s_valid=0;repeat(8) @(negedge clk);abort=1;@(negedge clk);abort=0;held=0;
        for(frame=0;frame<FRAMES;frame=frame+1) begin
            got=0;sent=0;{cfg_mode,cfg_edge_threshold,cfg_binary_threshold}=configs[frame];
            while(got<N) begin
                m_ready=($urandom_range(0,7)!=0);
                if(!s_valid && sent<N && $urandom_range(0,3)!=0) begin
                    s_valid=1;s_data=source[frame*N+sent];s_sof=(sent==0);
                    s_eol=(sent%W==W-1);s_eof=(sent==N-1);
                end
                @(posedge clk);
                if(s_valid && s_ready) begin sent=sent+1;@(negedge clk);s_valid=0;end
                else @(negedge clk);
                if(sent>3) {cfg_mode,cfg_edge_threshold,cfg_binary_threshold}=~configs[frame];
            end
            repeat(8) @(negedge clk);
            if(sent!=N || frames_started!=frame+1 || {active_mode,active_edge_threshold,active_binary_threshold}!==configs[frame])
                $fatal(1,"Frame-latched status mismatch");
        end
        $display("PASS YUV preprocessing: %0d frames %0dx%0d, four modes, threshold extremes, borders, stalls, abort and frame-latched status (%0d cycles)",FRAMES,W,H,cycles);
        $finish;
    end
    initial begin #(64'd100*N*FRAMES+1000000);$fatal(1,"Preprocess timeout sent=%0d got=%0d",sent,got);end
endmodule
