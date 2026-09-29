`timescale 1ns/1ps
module tb_bayer_bggr #(parameter W=16,H=8,FRAMES=3,BAYER_PATTERN=0,DENOISE_ENABLE=0,DENOISE_STRENGTH=0);
    localparam N=W*H;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,abort=0;
    reg [7:0] s_data;
    reg s_valid=0,s_sof=0,s_eol=0,s_eof=0;
    wire s_ready;
    wire [15:0] m_data;
    wire m_valid,m_sof,m_eol,m_eof;
    reg m_ready=0;
    wire [7:0] cfg_denoise_strength=DENOISE_STRENGTH;
    reg [7:0] raw[0:FRAMES*N-1];
    reg [15:0] golden[0:FRAMES*N-1];
    integer sent=0,got=0,frame=0,cycles=0;
    reg held=0;reg [18:0] held_word;
    bayer_bggr_to_yuv422 #(.WIDTH(W),.HEIGHT(H),.BAYER_PATTERN(BAYER_PATTERN),.DENOISE_ENABLE(DENOISE_ENABLE)) dut(.*);
    always @(posedge clk) if(rst_n && !abort) begin
        cycles=cycles+1;
        if(held && {m_eof,m_eol,m_sof,m_data}!==held_word) $fatal(1,"output changed under backpressure");
        held=m_valid && !m_ready;held_word={m_eof,m_eol,m_sof,m_data};
        if(m_valid && m_ready) begin
            if(got>=N || m_data!==golden[frame*N+got])
                $fatal(1,"Bayer mismatch frame=%0d pixel=%0d got=%04x expected=%04x",frame,got,m_data,golden[frame*N+got]);
            if(m_sof!=(got==0) || m_eol!=(got%W==W-1) || m_eof!=(got==N-1)) $fatal(1,"marker mismatch at %0d",got);
            got=got+1;
        end
    end
    initial begin
        $readmemh("raw.mem",raw);$readmemh("golden.mem",golden);
        repeat(10) @(negedge clk);rst_n=1;
        // Aborting while a partially fed image is blocked must discard it.
        m_ready=0;
        for(sent=0;sent<W+3;sent=sent+1) begin
            s_valid=1;s_data=raw[sent];s_sof=(sent==0);s_eol=(sent%W==W-1);s_eof=0;
            @(posedge clk);while(!s_ready) @(posedge clk);
            @(negedge clk);
        end
        s_valid=0;repeat(8) @(negedge clk);
        abort=1;@(negedge clk);abort=0;held=0;
        for(frame=0;frame<FRAMES;frame=frame+1) begin
            got=0;sent=0;
            while(got<N) begin
                m_ready=($urandom_range(0,7)!=0);
                if(!s_valid && sent<N && $urandom_range(0,3)!=0) begin
                    s_valid=1;s_data=raw[frame*N+sent];
                    s_sof=(sent==0);s_eol=(sent%W==W-1);s_eof=(sent==N-1);
                end
                @(posedge clk);
                if(s_valid && s_ready) begin sent=sent+1;@(negedge clk);s_valid=0;end
                else @(negedge clk);
            end
            if(sent!=N) $fatal(1,"wrong input count");
            repeat(8) @(negedge clk);
        end
        $display("PASS reflected Bayer pattern=%0d bilinear, independent reference, %0d frames %0dx%0d, random input/output stalls, abort recovery (%0d cycles)",BAYER_PATTERN,FRAMES,W,H,cycles);
        $finish;
    end
    initial begin #(64'd100*N*FRAMES+1000000);$fatal(1,"Bayer simulation timeout sent=%0d got=%0d mode=%0d",sent,got,dut.mode);end
endmodule
