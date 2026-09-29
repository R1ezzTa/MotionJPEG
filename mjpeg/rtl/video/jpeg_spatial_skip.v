// Exact spatial reuse of JPEG restart intervals. Cache entries have fixed
// spatial indices; comparison includes every byte and the original length.
// Uncached/oversized groups are always transmitted. Optional dead zone compares
// decoded, dequantized DCT coefficients against the last transmitted reference.
// SPJ1: magic, key u8, reference LE32, header(tag0,length LE16,bytes),
// then DATA(tag1,index LE16,length LE16,bytes) or COPY(tag2,index LE16).
module jpeg_spatial_skip #(
    parameter CACHE_SLOTS=192,CACHE_SLOT_BYTES=256,CACHE_STRIDE=21,REFRESH_PERIOD=30,THRESHOLD_ENABLE=0
)(
    input clk,rst_n,invalidate,
    input [31:0] frame_id,input [15:0] width,height,input gray,
    input [7:0] cfg_threshold,input cfg_q_valid,input [6:0] cfg_q_addr,input [7:0] cfg_q_value,
    input [127:0] s_data,input [4:0] s_bytes,input s_last,s_valid,output s_ready,
    output [127:0] m_data,output [4:0] m_bytes,output m_last,m_valid,input m_ready
);
    localparam HEADER_IN=0,FRAME_PREFIX=1,HEADER_PRIME=2,HEADER_OUT=3,
        GROUP_IN=4,DECIDE=5,COMPARE_PRIME=6,COMPARE=7,GROUP_PREFIX=8,
        GROUP_PRIME=9,GROUP_OUT=10,COEFF_START=11,COEFF_RUN=12;
    reg [3:0] state;
    reg [127:0] input_word;reg [4:0] input_remaining;reg input_last;
    reg [12:0] write_index,read_index;
    reg [13:0] group_length;
    reg ingest_active,write_bank,read_bank;
    reg [1:0] bank_ready;
    reg [13:0] bank_length[0:1];reg bank_last[0:1];reg [15:0] bank_group[0:1];
    reg [12:0] ingest_index;reg [15:0] ingest_group;
    reg [15:0] group_index,stride_index,slot_index;
    reg [13:0] compare_index;
    reg previous_ff,last_group,copy_group,equal_group,keyframe,reference_valid;
    reg [31:0] previous_id;
    reg [15:0] previous_width,previous_height,frames_since_refresh;
    reg previous_gray;
    reg [111:0] prefix;reg [4:0] prefix_remaining;
    reg [7:0] frame_threshold,previous_threshold;
    reg [CACHE_SLOTS-1:0] cache_valid;
    (* ram_style="distributed" *) reg [8:0] cache_length[0:CACHE_SLOTS-1];
    (* ram_style="block" *) reg [7:0] group_ram[0:16383];
    (* ram_style="block" *) reg [7:0] cache_ram[0:CACHE_SLOTS*CACHE_SLOT_BYTES-1];
    reg [7:0] group_q,cache_q;
    `include "rtl/generated/zigzag.vh"
    (* ram_style="distributed" *) reg [7:0] quant_table[0:127];
    always @(posedge clk) if(THRESHOLD_ENABLE && cfg_q_valid) quant_table[cfg_q_addr]<=cfg_q_value;
    reg [13:0] coefficient_current_pos,coefficient_reference_pos;
    reg coefficient_current_pending,coefficient_reference_pending;
    reg coefficient_current_last,coefficient_reference_last,coefficient_mismatch;
    wire current_byte_ready,reference_byte_ready,current_done,reference_done,current_error,reference_error;
    wire current_coefficient_valid,reference_coefficient_valid;
    wire [9:0] current_coefficient_index,reference_coefficient_index;
    wire signed [15:0] current_coefficient_value,reference_coefficient_value;
    wire current_coefficient_ready,reference_coefficient_ready;
    wire current_byte_read=THRESHOLD_ENABLE && state==COEFF_RUN &&
        (!coefficient_current_pending || current_byte_ready) && coefficient_current_pos<group_length-2;
    wire reference_byte_read=THRESHOLD_ENABLE && state==COEFF_RUN &&
        (!coefficient_reference_pending || reference_byte_ready) && coefficient_reference_pos<cache_length[slot_index]-2;
    generate if(THRESHOLD_ENABLE) begin: coefficient_decoders
        jpeg_coefficient_decoder current_decoder(
            .clk(clk),.rst_n(rst_n),.start(state==COEFF_START),.gray(gray),
            .s_data(group_q),.s_valid(coefficient_current_pending && state==COEFF_RUN),.s_ready(current_byte_ready),
            .s_last(coefficient_current_last),.m_index(current_coefficient_index),.m_value(current_coefficient_value),
            .m_valid(current_coefficient_valid),.m_ready(current_coefficient_ready),.done(current_done),.error(current_error));
        jpeg_coefficient_decoder reference_decoder(
            .clk(clk),.rst_n(rst_n),.start(state==COEFF_START),.gray(gray),
            .s_data(cache_q),.s_valid(coefficient_reference_pending && state==COEFF_RUN),.s_ready(reference_byte_ready),
            .s_last(coefficient_reference_last),.m_index(reference_coefficient_index),.m_value(reference_coefficient_value),
            .m_valid(reference_coefficient_valid),.m_ready(reference_coefficient_ready),.done(reference_done),.error(reference_error));
    end else begin: no_coefficient_decoders
        assign current_byte_ready=0;assign reference_byte_ready=0;
        assign current_done=0;assign reference_done=0;assign current_error=0;assign reference_error=0;
        assign current_coefficient_valid=0;assign reference_coefficient_valid=0;
        assign current_coefficient_index=0;assign reference_coefficient_index=0;
        assign current_coefficient_value=0;assign reference_coefficient_value=0;
    end endgenerate
    // Merge two ordered sparse coefficient streams. Omitted AC values are zero.
    wire merge_available=state==COEFF_RUN && (current_coefficient_valid || current_done) &&
        (reference_coefficient_valid || reference_done);
    wire merge_current=merge_available && current_coefficient_valid &&
        (!reference_coefficient_valid || current_coefficient_index<=reference_coefficient_index);
    wire merge_reference=merge_available && reference_coefficient_valid &&
        (!current_coefficient_valid || reference_coefficient_index<=current_coefficient_index);
    assign current_coefficient_ready=merge_current;
    assign reference_coefficient_ready=merge_reference;
    wire [9:0] merge_index=merge_current?current_coefficient_index:reference_coefficient_index;
    wire signed [16:0] coefficient_difference=(merge_current?$signed(current_coefficient_value):17'sd0)-
        (merge_reference?$signed(reference_coefficient_value):17'sd0);
    wire [6:0] coefficient_q_address={(!gray && merge_index[7]),zigzag(merge_index[5:0])};
    reg comparison_valid1,comparison_valid2;
    reg [16:0] comparison_magnitude;reg [7:0] comparison_quant;
    reg [24:0] comparison_dequantized;
    wire [9:0] header_length=gray?603:613;
    wire selected=stride_index==0 && slot_index<CACHE_SLOTS;
    wire fits=group_length<=CACHE_SLOT_BYTES;
    wire input_phase=state==HEADER_IN || (ingest_active && !bank_ready[write_bank]);
    assign s_ready=input_phase && input_remaining==0;
    wire byte_take=input_phase && input_remaining!=0;
    wire [7:0] incoming=input_word[7:0];
    wire marker=ingest_active && previous_ff &&
        ((incoming>=8'hd0 && incoming<=8'hd7) || incoming==8'hd9);
    assign m_valid=state==FRAME_PREFIX || state==HEADER_OUT ||
        state==GROUP_PREFIX || state==GROUP_OUT;
    wire [7:0] outgoing=(state==FRAME_PREFIX || state==GROUP_PREFIX)?prefix[7:0]:group_q;
    assign m_data={120'd0,outgoing};assign m_bytes=1;
    assign m_last=last_group && ((state==GROUP_PREFIX && copy_group && prefix_remaining==1) ||
        (state==GROUP_OUT && read_index==group_length-1));
    wire out_take=m_valid && m_ready;
    wire read_group=current_byte_read || state==HEADER_PRIME || state==GROUP_PRIME || state==COMPARE_PRIME ||
        state==COMPARE || ((state==HEADER_OUT || state==GROUP_OUT) && out_take);
    wire [12:0] group_read_offset=current_byte_read?coefficient_current_pos[12:0]:
        (state==HEADER_PRIME || state==GROUP_PRIME || state==COMPARE_PRIME)?0:
        state==COMPARE?compare_index[12:0]+1'b1:read_index+1'b1;
    wire [13:0] group_read_address={(state==HEADER_PRIME || state==HEADER_OUT)?1'b0:read_bank,group_read_offset};
    wire [13:0] group_write_address=state==HEADER_IN?{1'b0,write_index}:{write_bank,ingest_index};
    wire read_cache=reference_byte_read || state==COMPARE_PRIME || state==COMPARE;
    wire [15:0] cache_read_address=slot_index*CACHE_SLOT_BYTES+
        (reference_byte_read?coefficient_reference_pos:(state==COMPARE_PRIME?0:compare_index+1'b1));
    wire write_cache=state==GROUP_OUT && out_take && selected && fits;
    wire [15:0] cache_write_address=slot_index*CACHE_SLOT_BYTES+read_index;
    // Simple dual-port BRAM; reset touches only validity, never data arrays.
    always @(posedge clk) begin
        if(byte_take) group_ram[group_write_address]<=incoming;
        if(read_group) group_q<=group_ram[group_read_address];
        if(read_cache) cache_q<=cache_ram[cache_read_address];
        if(write_cache) cache_ram[cache_write_address]<=outgoing;
        if(state==GROUP_OUT && out_take && selected && fits && read_index==group_length-1)
            cache_length[slot_index]<=group_length;
    end
    wire group_sent=out_take && ((state==GROUP_PREFIX && copy_group && prefix_remaining==1) ||
        (state==GROUP_OUT && read_index==group_length-1));
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=HEADER_IN;input_word<=0;input_remaining<=0;input_last<=0;
            write_index<=0;read_index<=0;group_length<=0;group_index<=0;
            stride_index<=0;slot_index<=0;compare_index<=0;previous_ff<=0;
            last_group<=0;copy_group<=0;equal_group<=0;keyframe<=1;reference_valid<=0;
            previous_id<=32'hffffffff;previous_width<=0;previous_height<=0;previous_gray<=0;
            frames_since_refresh<=0;prefix<=0;prefix_remaining<=0;cache_valid<=0;
            frame_threshold<=0;previous_threshold<=0;
            coefficient_current_pos<=0;coefficient_reference_pos<=0;
            coefficient_current_pending<=0;coefficient_reference_pending<=0;
            coefficient_current_last<=0;coefficient_reference_last<=0;coefficient_mismatch<=0;
            comparison_valid1<=0;comparison_valid2<=0;comparison_magnitude<=0;comparison_quant<=0;comparison_dequantized<=0;
            ingest_active<=0;write_bank<=0;read_bank<=0;bank_ready<=0;
            bank_length[0]<=0;bank_length[1]<=0;bank_last[0]<=0;bank_last[1]<=0;
            bank_group[0]<=0;bank_group[1]<=0;ingest_index<=0;ingest_group<=0;
        end else begin
            comparison_valid1<=THRESHOLD_ENABLE && (merge_current || merge_reference);
            comparison_valid2<=comparison_valid1;
            if(merge_current || merge_reference) begin
                comparison_magnitude<=coefficient_difference<0?-coefficient_difference:coefficient_difference;
                comparison_quant<=quant_table[coefficient_q_address];
            end
            if(comparison_valid1) comparison_dequantized<=comparison_magnitude*comparison_quant;
            if(comparison_valid2 && comparison_dequantized>frame_threshold) coefficient_mismatch<=1;
            if(current_byte_read) begin
                coefficient_current_pos<=coefficient_current_pos+1'b1;
                coefficient_current_pending<=1;
                coefficient_current_last<=coefficient_current_pos==group_length-3;
            end else if(coefficient_current_pending && current_byte_ready) coefficient_current_pending<=0;
            if(reference_byte_read) begin
                coefficient_reference_pos<=coefficient_reference_pos+1'b1;
                coefficient_reference_pending<=1;
                coefficient_reference_last<=coefficient_reference_pos==cache_length[slot_index]-3;
            end else if(coefficient_reference_pending && reference_byte_ready) coefficient_reference_pending<=0;
            if(s_valid && s_ready) begin
                input_word<=s_data;input_remaining<=s_bytes;input_last<=s_last;
            end else if(byte_take) begin
                input_word<={8'd0,input_word[127:8]};input_remaining<=input_remaining-1'b1;
            end
            if(byte_take && ingest_active) begin
                previous_ff<=incoming==8'hff;
                if(marker) begin
                    bank_ready[write_bank]<=1;bank_length[write_bank]<={1'b0,ingest_index}+1'b1;
                    bank_last[write_bank]<=input_last && input_remaining==1;
                    bank_group[write_bank]<=ingest_group;
                    write_bank<=!write_bank;ingest_index<=0;ingest_group<=ingest_group+1'b1;previous_ff<=0;
                    if(input_last && input_remaining==1) ingest_active<=0;
                end else ingest_index<=ingest_index+1'b1;
            end
            case(state)
                HEADER_IN: if(byte_take) begin
                    if(write_index==0) begin
                        frame_threshold<=THRESHOLD_ENABLE?cfg_threshold:0;
                        keyframe<=!reference_valid || frame_id!=previous_id+1'b1 ||
                            frames_since_refresh>=REFRESH_PERIOD || width!=previous_width ||
                            height!=previous_height || gray!=previous_gray || (THRESHOLD_ENABLE && cfg_threshold!=previous_threshold);
                        if(!reference_valid || frame_id!=previous_id+1'b1 || frames_since_refresh>=REFRESH_PERIOD ||
                           width!=previous_width || height!=previous_height || gray!=previous_gray || (THRESHOLD_ENABLE && cfg_threshold!=previous_threshold))
                            cache_valid<=0;
                    end
                    if(write_index==header_length-1) begin
                        if(THRESHOLD_ENABLE) begin
                            prefix<={6'd0,header_length,8'd0,frame_threshold,(keyframe?32'hffffffff:previous_id),7'd0,keyframe,32'h324a5053};
                            prefix_remaining<=13;
                        end else begin
                            prefix<={6'd0,header_length,8'd0,(keyframe?32'hffffffff:previous_id),7'd0,keyframe,32'h314a5053};
                            prefix_remaining<=12;
                        end
                        state<=FRAME_PREFIX;write_index<=0;
                    end else write_index<=write_index+1'b1;
                end
                FRAME_PREFIX: if(out_take) begin
                    prefix<=prefix>>8;prefix_remaining<=prefix_remaining-1'b1;
                    if(prefix_remaining==1) state<=HEADER_PRIME;
                end
                HEADER_PRIME: begin read_index<=0;state<=HEADER_OUT;end
                HEADER_OUT: if(out_take) begin
                    if(read_index==header_length-1) begin
                        state<=GROUP_IN;read_index<=0;ingest_active<=1;write_bank<=0;read_bank<=0;
                        ingest_index<=0;ingest_group<=0;previous_ff<=0;
                    end
                    else read_index<=read_index+1'b1;
                end
                GROUP_IN: if(bank_ready[read_bank]) begin
                    group_length<=bank_length[read_bank];last_group<=bank_last[read_bank];
                    group_index<=bank_group[read_bank];state<=DECIDE;
                end
                DECIDE: begin
                    copy_group<=0;
                    if(THRESHOLD_ENABLE && frame_threshold!=0 && !keyframe && selected && fits && cache_valid[slot_index]) begin
                        coefficient_current_pos<=0;coefficient_reference_pos<=0;
                        coefficient_current_pending<=0;coefficient_reference_pending<=0;
                        coefficient_current_last<=0;coefficient_reference_last<=0;coefficient_mismatch<=0;
                        comparison_valid1<=0;comparison_valid2<=0;state<=COEFF_START;
                    end else if(!keyframe && selected && fits && cache_valid[slot_index] && cache_length[slot_index]==group_length) begin
                        compare_index<=0;equal_group<=1;state<=COMPARE_PRIME;
                    end else begin
                        prefix<={56'd0,2'd0,group_length,group_index,8'd1};
                        prefix_remaining<=5;state<=GROUP_PREFIX;
                        if(selected && !fits) cache_valid[slot_index]<=0;
                    end
                end
                COMPARE_PRIME: state<=COMPARE;
                COEFF_START: state<=COEFF_RUN;
                COEFF_RUN: begin
                    if(current_error || reference_error ||
                       (current_done && reference_done && !comparison_valid1 && !comparison_valid2)) begin
                        copy_group<=!current_error && !reference_error && !coefficient_mismatch;
                        if(!current_error && !reference_error && !coefficient_mismatch) begin
                            prefix<={72'd0,group_index,8'd2};prefix_remaining<=3;
                        end else begin
                            prefix<={56'd0,2'd0,group_length,group_index,8'd1};prefix_remaining<=5;
                        end
                        coefficient_current_pending<=0;coefficient_reference_pending<=0;state<=GROUP_PREFIX;
                    end
                end
                COMPARE: begin
                    equal_group<=equal_group && group_q==cache_q;
                    if(compare_index==group_length-1) begin
                        copy_group<=equal_group && group_q==cache_q;
                        if(equal_group && group_q==cache_q) begin
                            prefix<={72'd0,group_index,8'd2};prefix_remaining<=3;
                        end else begin
                            prefix<={56'd0,2'd0,group_length,group_index,8'd1};prefix_remaining<=5;
                        end
                        state<=GROUP_PREFIX;
                    end else compare_index<=compare_index+1'b1;
                end
                GROUP_PREFIX: if(out_take) begin
                    prefix<=prefix>>8;prefix_remaining<=prefix_remaining-1'b1;
                    if(prefix_remaining==1 && !copy_group) state<=GROUP_PRIME;
                end
                GROUP_PRIME: begin read_index<=0;state<=GROUP_OUT;end
                GROUP_OUT: if(out_take) begin
                    if(selected && fits && read_index==group_length-1) cache_valid[slot_index]<=1;
                    read_index<=read_index+1'b1;
                end
                default:state<=HEADER_IN;
            endcase
            if(group_sent) begin
                read_index<=0;write_index<=0;bank_ready[read_bank]<=0;read_bank<=!read_bank;
                if(last_group) begin
                    previous_id<=frame_id;reference_valid<=1;previous_width<=width;
                    previous_height<=height;previous_gray<=gray;
                    previous_threshold<=frame_threshold;
                    frames_since_refresh<=keyframe?1:frames_since_refresh+1'b1;
                    group_index<=0;stride_index<=0;slot_index<=0;last_group<=0;state<=HEADER_IN;
                end else begin
                    group_index<=group_index+1'b1;state<=GROUP_IN;
                    if(stride_index==CACHE_STRIDE-1) begin stride_index<=0;slot_index<=slot_index+1'b1;end
                    else stride_index<=stride_index+1'b1;
                end
            end
            if(invalidate) begin reference_valid<=0;cache_valid<=0;frames_since_refresh<=0;end
        end
    end
endmodule
