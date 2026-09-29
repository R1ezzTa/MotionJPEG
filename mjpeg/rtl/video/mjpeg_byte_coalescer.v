// Resource-efficient specialization for SPJ, which emits one byte per beat.
// Sixteen visible bytes plus one overflow byte retain the original capacity
// and simultaneous pop/push behavior without a variable 256-bit shifter.
module mjpeg_byte_coalescer(
    input clk,rst_n,input [127:0] s_data,input [4:0] s_bytes,
    input s_first,s_last,s_valid,output s_ready,
    input [1:0] s_channel,input [31:0] s_frame_id,input flush,
    output [127:0] m_data,output [4:0] m_bytes,
    output m_first,m_last,m_valid,input m_ready,
    output [1:0] m_channel,output [31:0] m_frame_id,output idle
);
    reg [135:0] data;
    reg [5:0] count;
    reg first,ending,aborting;
    reg [1:0] channel;
    reg [31:0] frame_id;
    wire same_frame=s_channel==channel && s_frame_id==frame_id;
    assign idle=count==0 && !ending;
    assign s_ready=!ending && count<=16 && (count==0 || (same_frame && !flush));
    assign m_valid=count>=16 || ending || (count!=0 && (flush || (s_valid && !same_frame)));
    assign m_data=data[127:0];
    assign m_bytes=count>=16?5'd16:count[4:0];
    assign m_first=first;
    assign m_last=ending && count<=16 && (!aborting || count==0);
    assign m_channel=channel;assign m_frame_id=frame_id;
    wire push=s_valid && s_ready,pop=m_valid && m_ready;
    wire [5:0] position=pop?count-m_bytes:count;
    genvar b;
    generate for(b=0;b<17;b=b+1) begin: bytes
        always @(posedge clk) begin
            if(pop) data[b*8+:8]<=(b==0 && count==17)?data[128+:8]:8'd0;
            if(push && s_bytes!=0 && position==b) data[b*8+:8]<=s_data[7:0];
        end
    end endgenerate
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin count<=0;first<=0;ending<=0;aborting<=0;channel<=0;frame_id<=0;end
        else begin
            count<=position+(push && s_bytes!=0);
            if(pop) begin
                first<=0;
                if(m_last) begin ending<=0;aborting<=0;end
            end
            if(push) begin
                if(count==0) begin first<=s_first;channel<=s_channel;frame_id<=s_frame_id;end
                if(s_last) begin ending<=1;aborting<=s_bytes==0;end
            end
        end
    end
endmodule
