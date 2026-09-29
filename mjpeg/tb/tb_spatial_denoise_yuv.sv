`timescale 1ns/1ps
module tb_spatial_denoise_yuv #(parameter W=16,H=8,FRAMES=17);
    localparam N=W*H;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,abort=0;
    reg [7:0] cfg_strength=0;
    reg [23:0] s_data=0;
    reg s_valid=0,s_sof=0,s_eol=0,s_eof=0;
    wire s_ready;
    wire [23:0] m_data;
    wire m_valid,m_sof,m_eol,m_eof,m_odd;
    reg m_ready=0;
    reg [23:0] rgb[0:FRAMES*N-1],golden[0:FRAMES*N-1];
    reg [7:0] strengths[0:FRAMES-1];
    integer sent=0,got=0,frame=0,cycles=0;
    reg held=0;reg [27:0] held_word;
    spatial_denoise_yuv #(.WIDTH(W),.HEIGHT(H)) dut(.*);
    always @(posedge clk) if(rst_n && !abort) begin
        cycles=cycles+1;
        if(held && (!m_valid || {m_odd,m_eof,m_eol,m_sof,m_data}!==held_word)) $fatal(1,"NR output changed under backpressure");
        held=m_valid && !m_ready;held_word={m_odd,m_eof,m_eol,m_sof,m_data};
        if(m_valid && m_ready) begin
            if(got>=N || m_data!==golden[frame*N+got])
                $fatal(1,"NR mismatch frame=%0d pixel=%0d got=%06x expected=%06x",frame,got,m_data,golden[frame*N+got]);
            if(m_sof!=(got==0) || m_eol!=(got%W==W-1) || m_eof!=(got==N-1) || m_odd!=(got%2)) $fatal(1,"NR marker mismatch at %0d",got);
            got=got+1;
        end
    end
    initial begin
        $readmemh("rgb.mem",rgb);$readmemh("golden.mem",golden);$readmemh("strength.mem",strengths);
        repeat(10) @(negedge clk);rst_n=1;cfg_strength=255;
        // Dirty line RAM and a blocked output must disappear on abort.
        for(sent=0;sent<W+3;sent=sent+1) begin
            s_valid=1;s_data=rgb[sent];s_sof=(sent==0);s_eol=(sent%W==W-1);s_eof=0;
            @(posedge clk);while(!s_ready) @(posedge clk);
            @(negedge clk);
        end
        s_valid=0;repeat(8) @(negedge clk);abort=1;@(negedge clk);abort=0;held=0;
        for(frame=0;frame<FRAMES;frame=frame+1) begin
            got=0;sent=0;cfg_strength=strengths[frame];
            while(got<N) begin
                m_ready=($urandom_range(0,7)!=0);
                if(!s_valid && sent<N && $urandom_range(0,3)!=0) begin
                    s_valid=1;s_data=rgb[frame*N+sent];s_sof=(sent==0);
                    s_eol=(sent%W==W-1);s_eof=(sent==N-1);
                end
                @(posedge clk);
                if(s_valid && s_ready) begin sent=sent+1;@(negedge clk);s_valid=0;end
                else @(negedge clk);
                // Settings change during a frame must wait until next SOF.
                if(sent>3) cfg_strength=255-strengths[frame];
            end
            if(sent!=N) $fatal(1,"NR input count");
            repeat(8) @(negedge clk);
        end
        $display("PASS robust YUV denoise independent reference: %0d frames %0dx%0d, zero bypass, frame-latched configuration, motion, borders, stalls and abort (%0d cycles)",FRAMES,W,H,cycles);
        $finish;
    end
    initial begin #(64'd100*N*FRAMES+1000000);$fatal(1,"NR simulation timeout sent=%0d got=%0d",sent,got);end
endmodule

