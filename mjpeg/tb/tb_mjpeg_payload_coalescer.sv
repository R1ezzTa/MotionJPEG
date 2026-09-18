`timescale 1ns/1ps
module tb_mjpeg_payload_coalescer;
    reg clk=0,rst_n=0;
    always #10 clk=~clk;
    reg [127:0] s_data=0;
    reg [4:0] s_bytes=0;
    reg s_first=0,s_last=0,s_valid=0,flush=0;
    reg [1:0] s_channel=0;
    reg [31:0] s_frame_id=0;
    wire s_ready,m_first,m_last,m_valid,idle;
    wire [127:0] m_data;
    wire [4:0] m_bytes;
    wire [1:0] m_channel;
    wire [31:0] m_frame_id;
    reg m_ready=0;
    integer cycles=0,outputs=0,marker;
    integer expected_count[0:5],received_count[0:5],starts[0:5],ends[0:5];
    reg [7:0] expected[0:5][0:127];
    reg aborted[0:5];
    reg stalled=0;
    reg [168:0] held;
    mjpeg_payload_coalescer dut(.*);
    always @(negedge clk) m_ready=(cycles%37)<13;
    integer b;
    always @(posedge clk) if(rst_n) begin
        cycles=cycles+1;
        if(cycles>5000) $fatal(1,"Coalescer watchdog");
        if(stalled && (!m_valid || held!=={m_channel,m_frame_id,m_first,m_last,m_bytes,m_data}))
            $fatal(1,"Output changed under backpressure");
        stalled=m_valid && !m_ready;
        held={m_channel,m_frame_id,m_first,m_last,m_bytes,m_data};
        if(m_valid && m_ready) begin
            if(m_frame_id>5 || m_channel!==(m_frame_id&1)) $fatal(1,"Frame/channel mixing");
            if(m_first) begin
                if(starts[m_frame_id]!=0 || received_count[m_frame_id]!=0) $fatal(1,"Duplicate/misplaced first");
                starts[m_frame_id]=starts[m_frame_id]+1;
            end
            if(starts[m_frame_id]!=1 || ends[m_frame_id]!=0) $fatal(1,"Frame order");
            for(b=0;b<m_bytes;b=b+1) begin
                if(m_data[b*8+:8]!==expected[m_frame_id][received_count[m_frame_id]]) $fatal(1,"JPEG byte changed");
                received_count[m_frame_id]=received_count[m_frame_id]+1;
            end
            if(m_last) begin
                if(received_count[m_frame_id]!=expected_count[m_frame_id] || (m_bytes==0)!==aborted[m_frame_id])
                    $fatal(1,"Last/abort marker moved or dropped");
                ends[m_frame_id]=ends[m_frame_id]+1;
            end
            outputs=outputs+1;
        end
    end
    task send(input integer id,input integer n,input bit first,input bit last);
        integer j;
        begin
            @(negedge clk);
            s_data='1;s_bytes=n;s_first=first;s_last=last;s_frame_id=id;s_channel=id&1;s_valid=1;
            for(j=0;j<n;j=j+1) begin
                s_data[j*8+:8]=(id*37+expected_count[id])&255;
                expected[id][expected_count[id]]=s_data[j*8+:8];expected_count[id]=expected_count[id]+1;
            end
            if(last && n==0) aborted[id]=1;
            @(posedge clk);while(!s_ready) @(posedge clk);
            @(negedge clk);s_valid=0;
        end
    endtask
    integer k;
    initial begin
        for(k=0;k<6;k=k+1) begin expected_count[k]=0;received_count[k]=0;starts[k]=0;ends[k]=0;aborted[k]=0; end
        repeat(5) @(negedge clk);rst_n=1;
        send(0,7,1,0);send(1,16,1,0);send(0,5,0,1);send(1,16,0,1);
        send(2,1,1,0);send(2,0,0,1);send(3,16,1,0);send(3,0,0,1);
        send(4,3,1,0);@(negedge clk);flush=1;wait(idle);@(negedge clk);flush=0;
        send(4,16,0,1);send(5,16,1,1);
        wait(idle);repeat(3) @(negedge clk);
        for(k=0;k<6;k=k+1)
            if(starts[k]!=1 || ends[k]!=1 || received_count[k]!=expected_count[k]) $fatal(1,"Incomplete coalesced frame");
        marker=$fopen("COALESCER_PASS.txt","w");
        $fdisplay(marker,"Byte equality, interleaved channels, full/partial tails, explicit flush, abort markers and output stability under stalls passed");
        $fclose(marker);$finish;
    end
endmodule
