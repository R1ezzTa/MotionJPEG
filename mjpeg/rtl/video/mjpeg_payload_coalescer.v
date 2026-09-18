// Aggregate short JPEG beats into 16-byte beats without changing JPEG bytes.
// Keep an extra beat of capacity; input ready depends on local occupancy.
// A zero-byte last beat is an abort marker and must remain a separate beat.
module mjpeg_payload_coalescer(
    input clk,rst_n,
    input [127:0] s_data,input [4:0] s_bytes,
    input s_first,s_last,s_valid,output s_ready,
    input [1:0] s_channel,input [31:0] s_frame_id,
    input flush,
    output [127:0] m_data,output [4:0] m_bytes,
    output m_first,m_last,m_valid,input m_ready,
    output [1:0] m_channel,output [31:0] m_frame_id,
    output idle
);
    reg [255:0] data,next_data;
    reg [5:0] count,next_count;
    reg first,ending,aborting;
    reg [1:0] channel;
    reg [31:0] frame_id;
    wire same_frame=s_channel==channel && s_frame_id==frame_id;
    assign idle=count==0 && !ending;
    assign s_ready=!ending && count<=16 &&
                   (count==0 || (same_frame && !flush));
    assign m_valid=count>=16 || ending ||
                   (count!=0 && (flush || (s_valid && !same_frame)));
    assign m_data=data[127:0];
    assign m_bytes=count>=16 ? 5'd16 : count[4:0];
    assign m_first=first;
    assign m_last=ending && count<=16 && (!aborting || count==0);
    assign m_channel=channel;
    assign m_frame_id=frame_id;
    wire push=s_valid && s_ready;
    wire pop=m_valid && m_ready;
    wire [127:0] valid_data=s_data & (128'hffffffffffffffffffffffffffffffff >> ((16-s_bytes)*8));
    always @* begin
        next_data=data;
        next_count=count;
        if(pop) begin
            next_data=data >> (m_bytes*8);
            next_count=count-m_bytes;
        end
        if(push) begin
            next_data=next_data | ({128'd0,valid_data} << (next_count*8));
            next_count=next_count+s_bytes;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            data<=0;count<=0;first<=0;ending<=0;aborting<=0;channel<=0;frame_id<=0;
        end else begin
            data<=next_data;count<=next_count;
            if(pop) begin
                first<=0;
                if(m_last) begin ending<=0;aborting<=0; end
            end
            if(push) begin
                if(count==0) begin first<=s_first;channel<=s_channel;frame_id<=s_frame_id; end
                if(s_last) begin ending<=1;aborting<=s_bytes==0; end
            end
        end
    end
endmodule
