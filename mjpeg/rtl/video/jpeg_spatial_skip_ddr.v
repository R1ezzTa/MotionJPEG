// Exact spatial reuse of JPEG restart intervals. Cache entries have fixed
// spatial indices; comparison includes every byte and the original length.
// Uncached/oversized groups are always transmitted. Optional dead zone compares
// decoded, dequantized DCT coefficients against the last transmitted reference.
// SPJ1: magic, key u8, reference LE32, header(tag0,length LE16,bytes),
// then DATA(tag1,index LE16,length LE16,bytes) or COPY(tag2,index LE16).
// Full spatial-position DDR3 reference. rst_n is the global bridge reset;
// abort drains an accepted memory command before clearing the local pipeline.
module jpeg_spatial_skip_ddr #(
    parameter CACHE_SLOTS=4050,CACHE_SLOT_BYTES=8192,REFRESH_PERIOD=30,THRESHOLD_ENABLE=1,
    ADAPTIVE_ENABLE=0,ADAPTIVE_MAX_COPY=2,ADAPTIVE_COMPARE_CYCLES=384
)(
    input clk,rst_n,invalidate,abort,output recovering,output reg mem_fault,
    input [31:0] frame_id,input [15:0] width,height,input gray,
    input [7:0] cfg_threshold,input cfg_adaptive,input input_pressure,input cfg_q_valid,input [6:0] cfg_q_addr,input [7:0] cfg_q_value,
    input [127:0] s_data,input [4:0] s_bytes,input s_last,s_valid,output s_ready,
    output [127:0] m_data,output [4:0] m_bytes,output m_last,m_valid,input m_ready,
    output cmd_valid,input cmd_ready,output cmd_write,output [27:0] cmd_addr,output [13:0] cmd_bytes,
    output [127:0] w_data,output [15:0] w_keep,output w_valid,input w_ready,output w_last,
    input [127:0] r_data,input r_valid,output r_ready,input r_last,
    input mem_done,mem_error,output mem_active
);
    localparam HEADER_IN=0,FRAME_PREFIX=1,HEADER_PRIME=2,HEADER_OUT=3,
        GROUP_IN=4,DECIDE=5,COMPARE_PRIME=6,COMPARE=7,GROUP_PREFIX=8,
        GROUP_PRIME=9,GROUP_OUT=10,COEFF_START=11,COEFF_RUN=12,
        META_PRIME=16,META_LOAD=17,READ_CMD=18,READ_TRANSFER=19,
        WRITE_CMD=20,WRITE_WAIT=21,ABORT_DRAIN=22;
    reg [4:0] state;
    reg [127:0] input_word;reg [4:0] input_remaining;reg input_last;
    reg [12:0] write_index,read_index;
    reg [13:0] group_length;
    reg ingest_active,write_bank,read_bank;
    reg [1:0] bank_ready;
    reg [13:0] bank_length[0:1];reg bank_last[0:1];reg [15:0] bank_group[0:1];
    reg [12:0] ingest_index;reg [15:0] ingest_group;
    reg [15:0] group_index;
    reg [13:0] compare_index;
    reg previous_ff,last_group,copy_group,equal_group,keyframe,reference_valid;
    reg [31:0] previous_id;
    reg [15:0] previous_width,previous_height,frames_since_refresh;
    reg previous_gray;
    reg frame_invalidated;
    reg [111:0] prefix;reg [4:0] prefix_remaining;
    reg [7:0] frame_threshold,previous_threshold;
    reg frame_adaptive,previous_adaptive;
    // Four tolerance levels and a two-bit consecutive COPY age. Written only
    // after the region has really reached the host / DDR commit has completed.
    (* ram_style="block" *) reg [3:0] adaptive_meta[0:CACHE_SLOTS-1];
    reg [3:0] region_meta;
    reg [7:0] region_threshold;
    reg region_compared,region_safe,region_age_forced,local_mismatch;
    localparam ADAPTIVE_COUNTER_BITS=$clog2(ADAPTIVE_COMPARE_CYCLES+1);
    reg [ADAPTIVE_COUNTER_BITS-1:0] coefficient_cycles;
    // Length 0 is invalid. Global reference_valid/keyframe gates stale entries;
    // every completed full refresh rewrites all positions, so no reset write
    // port or generation counter is needed for this BRAM metadata.
    (* ram_style="block" *) reg [13:0] cache_length[0:CACHE_SLOTS-1];
    reg [13:0] reference_length;
    reg reference_loaded;
    (* ram_style="block" *) reg [7:0] group_ram[0:16383];
    (* ram_style="block" *) reg [127:0] reference_ram[0:511];
    reg [127:0] reference_word;
    reg [3:0] reference_lane;
    reg [7:0] group_q;
    wire [7:0] cache_q=reference_word >> (reference_lane*8);
    reg [31:0] active_id;
    reg [15:0] active_width,active_height;
    reg active_gray;
    reg recovery_reg,memory_busy,memory_write;
    reg [9:0] write_beats_remaining;
    reg [8:0] prefetch_word_index;
    reg [127:0] write_pack;
    reg [3:0] write_pack_count;
    reg write_pending,write_pending_last;
    reg [15:0] write_pending_keep;
    assign recovering=recovery_reg || abort || mem_fault;
    assign mem_active=memory_busy;
    assign cmd_valid=rst_n && !recovering && (state==READ_CMD || state==WRITE_CMD);
    assign cmd_write=state==WRITE_CMD;
    assign cmd_addr={group_index[14:0],13'd0};
    assign cmd_bytes=state==READ_CMD?reference_length:group_length;
    assign w_valid=rst_n && memory_busy && memory_write && write_beats_remaining!=0 &&
        (recovering || write_pending);
    // Preserve an already-presented W beat across abort/backpressure. Only
    // subsequent beats use keep=0; accepted transaction framing still completes.
    assign w_data=recovering && !write_pending?128'd0:write_pack;
    assign w_keep=recovering && !write_pending?16'd0:write_pending_keep;
    assign w_last=recovering && !write_pending?write_beats_remaining==1:write_pending_last;
    assign r_ready=rst_n && memory_busy && !memory_write && (recovering || state==READ_TRANSFER);
    always @(posedge clk) begin
        if(!rst_n) begin
            memory_busy<=0;memory_write<=0;write_beats_remaining<=0;mem_fault<=0;
        end else begin
            if(cmd_valid && cmd_ready) begin
                memory_busy<=1;memory_write<=cmd_write;
                write_beats_remaining<=({1'b0,cmd_bytes}+15)>>4;
            end
            if(w_valid && w_ready) write_beats_remaining<=write_beats_remaining-1'b1;
            if(mem_done) memory_busy<=0;
            if(mem_error) mem_fault<=1;
        end
    end
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
        (!coefficient_reference_pending || reference_byte_ready) && coefficient_reference_pos<reference_length-2;
    // Decode the prefetched reference and current entropy simultaneously. Each
    // ordered sparse stream holds its coefficient until the merge consumes it;
    // omitted coefficients are zero, including one-sided AC entries.
    // The decoder reset is synchronous. Stop both local pipelines outside a
    // comparison, including an early DATA rejection, without resetting DDR.
    wire coefficient_decode_reset_n=rst_n && !recovering &&
        (state==COEFF_START || state==COEFF_RUN);
    generate if(THRESHOLD_ENABLE) begin: coefficient_decoders
        jpeg_coefficient_decoder current_decoder(
            .clk(clk),.rst_n(coefficient_decode_reset_n),.start(state==COEFF_START),.gray(active_gray),
            .s_data(group_q),.s_valid(coefficient_current_pending && state==COEFF_RUN),
            .s_ready(current_byte_ready),.s_last(coefficient_current_last),
            .m_index(current_coefficient_index),.m_value(current_coefficient_value),
            .m_valid(current_coefficient_valid),.m_ready(current_coefficient_ready),
            .done(current_done),.error(current_error));
        jpeg_coefficient_decoder reference_decoder(
            .clk(clk),.rst_n(coefficient_decode_reset_n),.start(state==COEFF_START),.gray(active_gray),
            .s_data(cache_q),.s_valid(coefficient_reference_pending && state==COEFF_RUN),
            .s_ready(reference_byte_ready),.s_last(coefficient_reference_last),
            .m_index(reference_coefficient_index),.m_value(reference_coefficient_value),
            .m_valid(reference_coefficient_valid),.m_ready(reference_coefficient_ready),
            .done(reference_done),.error(reference_error));
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
    wire [6:0] coefficient_q_address={(!active_gray && merge_index[7]),zigzag(merge_index[5:0])};
    reg comparison_valid1,comparison_valid2;
    reg [16:0] comparison_magnitude;reg [7:0] comparison_quant;
    reg [24:0] comparison_dequantized;
    reg comparison_protected1,comparison_protected2;
    reg [17:0] comparison_sum;
    wire [17:0] adaptive_sum_limit={4'd0,frame_threshold,6'd0};
    wire local_failed=comparison_valid2 && comparison_dequantized>region_threshold;
    // Dense/noisy entropy at a large ceiling can keep both decoders busy long
    // enough to backpressure the live camera. Budget expiry chooses DATA; it
    // never permits a partially checked COPY or aborts the camera frame.
    wire adaptive_backlog=frame_adaptive && frame_threshold!=0 && (input_pressure || bank_ready[read_bank ^ 1'b1]);
    wire comparison_expired=frame_adaptive && (coefficient_cycles>=ADAPTIVE_COMPARE_CYCLES-1 || adaptive_backlog);
    // Protect DC/first five AC coefficients and every chroma coefficient.
    // The aggregate bound catches many small changes below the peak bound.
    wire comparison_failed=(comparison_valid2 &&
        (comparison_dequantized>frame_threshold || (frame_adaptive && comparison_protected2 &&
         comparison_dequantized>{1'b0,frame_threshold[7:1]}))) ||
        (frame_adaptive && comparison_sum>adaptive_sum_limit);
    function [7:0] adaptive_threshold;
        input [7:0] ceiling;input [1:0] level;
        begin
            case(level)
                0:adaptive_threshold=ceiling>>2;
                1:adaptive_threshold=ceiling>>1;
                2:adaptive_threshold=ceiling-(ceiling>>2);
                default:adaptive_threshold=ceiling;
            endcase
        end
    endfunction
    wire [9:0] header_length=(state==HEADER_IN && write_index==0?gray:active_gray)?603:613;
    wire selected=group_index<CACHE_SLOTS;
    wire fits=group_length<=CACHE_SLOT_BYTES;
    wire input_phase=rst_n && !recovering && (state==HEADER_IN || (ingest_active && !bank_ready[write_bank]));
    assign s_ready=input_phase && input_remaining==0;
    wire byte_take=input_phase && input_remaining!=0;
    wire [7:0] incoming=input_word[7:0];
    wire marker=ingest_active && previous_ff &&
        ((incoming>=8'hd0 && incoming<=8'hd7) || incoming==8'hd9);
    assign m_valid=rst_n && !recovering && (state==FRAME_PREFIX || state==HEADER_OUT ||
        state==GROUP_PREFIX || (state==GROUP_OUT && (!selected || !fits || !write_pending || w_ready)));
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
    wire [12:0] cache_read_address=reference_byte_read?coefficient_reference_pos[12:0]:
        (state==COMPARE_PRIME?13'd0:compare_index[12:0]+1'b1);
    // Simple dual-port BRAM; reset touches only validity, never data arrays.
    wire group_sent;
    always @(posedge clk) begin
        if(byte_take) group_ram[group_write_address]<=incoming;
        if(read_group) group_q<=group_ram[group_read_address];
        if(read_cache) begin
            reference_word<=reference_ram[cache_read_address[12:4]];
            reference_lane<=cache_read_address[3:0];
        end
        if(r_valid && r_ready && !recovering) reference_ram[prefetch_word_index]<=r_data;
        if(state==META_PRIME && selected) reference_length<=cache_length[group_index];
        if(ADAPTIVE_ENABLE && state==META_PRIME && selected) region_meta<=adaptive_meta[group_index];
        if(ADAPTIVE_ENABLE && group_sent && selected) begin
            if(keyframe || !frame_adaptive || !fits || frame_threshold==0)
                adaptive_meta[group_index]<=0;
            else if(region_age_forced)
                adaptive_meta[group_index]<={region_meta[3:2],2'd0};
            else if(region_compared && region_safe)
                adaptive_meta[group_index]<={(region_meta[3:2]==3?2'd3:region_meta[3:2]+2'd1),
                                            (copy_group?region_meta[1:0]+2'd1:2'd0)};
            else adaptive_meta[group_index]<=0;
        end
        if(state==WRITE_WAIT && mem_done && !mem_error && !recovering && selected && fits)
            cache_length[group_index]<=group_length;
        else if(state==DECIDE && selected && !fits && !recovering) cache_length[group_index]<=0;
    end
    assign group_sent=!recovering && ((out_take && state==GROUP_PREFIX && copy_group && prefix_remaining==1) ||
        (out_take && state==GROUP_OUT && (!selected || !fits) && read_index==group_length-1) ||
        (state==WRITE_WAIT && mem_done && !mem_error));
    task clear_stream;
        begin
            state<=HEADER_IN;input_word<=0;input_remaining<=0;input_last<=0;
            write_index<=0;read_index<=0;group_length<=0;group_index<=0;
            compare_index<=0;previous_ff<=0;
            last_group<=0;copy_group<=0;equal_group<=0;keyframe<=1;reference_valid<=0;
            previous_id<=32'hffffffff;previous_width<=0;previous_height<=0;previous_gray<=0;
            frame_invalidated<=0;
            frames_since_refresh<=0;prefix<=0;prefix_remaining<=0;
            frame_threshold<=0;previous_threshold<=0;
            frame_adaptive<=0;previous_adaptive<=0;region_threshold<=0;
            region_compared<=0;region_safe<=0;region_age_forced<=0;local_mismatch<=0;
            coefficient_cycles<=0;
            comparison_protected1<=0;comparison_protected2<=0;comparison_sum<=0;
            coefficient_current_pos<=0;coefficient_reference_pos<=0;
            coefficient_current_pending<=0;coefficient_reference_pending<=0;
            coefficient_current_last<=0;coefficient_reference_last<=0;coefficient_mismatch<=0;
            comparison_valid1<=0;comparison_valid2<=0;comparison_magnitude<=0;comparison_quant<=0;comparison_dequantized<=0;
            ingest_active<=0;write_bank<=0;read_bank<=0;bank_ready<=0;
            bank_length[0]<=0;bank_length[1]<=0;bank_last[0]<=0;bank_last[1]<=0;
            bank_group[0]<=0;bank_group[1]<=0;ingest_index<=0;ingest_group<=0;
            active_id<=0;active_width<=0;active_height<=0;active_gray<=0;
            write_pack<=0;write_pack_count<=0;write_pending<=0;write_pending_last<=0;write_pending_keep<=0;
            prefetch_word_index<=0;recovery_reg<=0;
            reference_loaded<=0;
        end
    endtask
    always @(posedge clk) begin
        if(!rst_n) begin
            clear_stream;
        end else if(abort || recovery_reg || mem_error || mem_fault) begin
            recovery_reg<=1;state<=ABORT_DRAIN;reference_valid<=0;frames_since_refresh<=0;
            if(w_valid && w_ready) write_pending<=0;
            if(!memory_busy && !abort && !mem_error && !mem_fault) clear_stream;
        end else begin
            if(w_valid && w_ready) write_pending<=0;
            if(r_valid && r_ready) prefetch_word_index<=prefetch_word_index+1'b1;
            if(state==GROUP_OUT && out_take && selected && fits) begin
                write_pack[write_pack_count*8+:8]<=outgoing;
                if(write_pack_count==15 || read_index==group_length-1) begin
                    write_pending<=1;write_pending_last<=read_index==group_length-1;
                    write_pending_keep<=16'hffff >> (15-write_pack_count);
                    write_pack_count<=0;
                end else write_pack_count<=write_pack_count+1'b1;
            end
            comparison_valid1<=THRESHOLD_ENABLE && (merge_current || merge_reference);
            comparison_valid2<=comparison_valid1;
            comparison_protected2<=comparison_protected1;
            if(merge_current || merge_reference) begin
                comparison_magnitude<=coefficient_difference<0?-coefficient_difference:coefficient_difference;
                comparison_quant<=quant_table[coefficient_q_address];
                comparison_protected1<=(merge_index[5:0]<6) || (!active_gray && merge_index[7]);
            end
            if(comparison_valid1) comparison_dequantized<=comparison_magnitude*comparison_quant;
            if(comparison_failed) coefficient_mismatch<=1;
            if(comparison_valid2 && frame_adaptive) comparison_sum<=comparison_sum+comparison_dequantized[17:0];
            if(local_failed) local_mismatch<=1;
            if(current_byte_read) begin
                coefficient_current_pos<=coefficient_current_pos+1'b1;
                coefficient_current_pending<=1;
                coefficient_current_last<=coefficient_current_pos==group_length-3;
            end else if(coefficient_current_pending && current_byte_ready) coefficient_current_pending<=0;
            if(reference_byte_read) begin
                coefficient_reference_pos<=coefficient_reference_pos+1'b1;
                coefficient_reference_pending<=1;
                coefficient_reference_last<=coefficient_reference_pos==reference_length-3;
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
                        active_id<=frame_id;active_width<=width;active_height<=height;active_gray<=gray;
                        frame_invalidated<=0;
                        frame_threshold<=THRESHOLD_ENABLE?cfg_threshold:0;
                        frame_adaptive<=THRESHOLD_ENABLE && ADAPTIVE_ENABLE && cfg_adaptive;
                        keyframe<=!reference_valid || frame_id!=previous_id+1'b1 ||
                            frames_since_refresh>=REFRESH_PERIOD || width!=previous_width ||
                            height!=previous_height || gray!=previous_gray || (THRESHOLD_ENABLE && cfg_threshold!=previous_threshold) ||
                            (ADAPTIVE_ENABLE && cfg_adaptive!=previous_adaptive);
                    end
                    if(write_index==header_length-1) begin
                        if(THRESHOLD_ENABLE) begin
                            prefix<={6'd0,header_length,8'd0,frame_threshold,(keyframe?32'hffffffff:previous_id),6'd0,frame_adaptive,keyframe,32'h324a5053};
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
                    group_index<=bank_group[read_bank];reference_loaded<=0;state<=META_PRIME;
                end
                META_PRIME: state<=META_LOAD;
                META_LOAD: begin
                    region_threshold<=frame_adaptive?adaptive_threshold(frame_threshold,region_meta[3:2]):frame_threshold;
                    region_age_forced<=frame_adaptive && !keyframe && frame_threshold!=0 && region_meta[1:0]>=ADAPTIVE_MAX_COPY;
                    region_compared<=0;region_safe<=0;state<=DECIDE;
                end
                DECIDE: begin
                    copy_group<=0;
                    // Exact mode can reject unequal lengths without reading DDR.
                    // Nonzero thresholds must still compare coefficient content
                    // because different entropy lengths may represent dead-zone noise.
                    if(!region_age_forced && !adaptive_backlog && !keyframe && selected && fits && reference_length!=0 && !reference_loaded &&
                       ((THRESHOLD_ENABLE && frame_threshold!=0) || reference_length==group_length)) begin
                        state<=READ_CMD;
                    end else if(!region_age_forced && !adaptive_backlog && THRESHOLD_ENABLE && frame_threshold!=0 && !keyframe && selected && fits && reference_length!=0) begin
                        coefficient_current_pos<=0;coefficient_reference_pos<=0;
                        coefficient_current_pending<=0;coefficient_reference_pending<=0;
                        coefficient_current_last<=0;coefficient_reference_last<=0;coefficient_mismatch<=0;
                        comparison_valid1<=0;comparison_valid2<=0;comparison_sum<=0;local_mismatch<=0;
                        region_compared<=1;state<=COEFF_START;
                    end else if(!region_age_forced && !adaptive_backlog && !(THRESHOLD_ENABLE && frame_threshold!=0) &&
                                !keyframe && selected && fits && reference_loaded && reference_length!=0 && reference_length==group_length) begin
                        compare_index<=0;equal_group<=1;state<=COMPARE_PRIME;
                    end else begin
                        prefix<={56'd0,2'd0,group_length,group_index,8'd1};
                        prefix_remaining<=5;state<=selected && fits?WRITE_CMD:GROUP_PREFIX;
                    end
                end
                READ_CMD: if(cmd_valid && cmd_ready) begin prefetch_word_index<=0;state<=READ_TRANSFER;end
                READ_TRANSFER: if(mem_done && !mem_error) begin reference_loaded<=1;state<=DECIDE;end
                WRITE_CMD: if(cmd_valid && cmd_ready) begin
                    write_pending<=0;write_pending_last<=0;write_pack_count<=0;state<=GROUP_PREFIX;
                end
                WRITE_WAIT: begin end
                COMPARE_PRIME: state<=COMPARE;
                COEFF_START: begin coefficient_cycles<=0;state<=COEFF_RUN;end
                COEFF_RUN: begin
                    if(frame_adaptive && !comparison_expired) coefficient_cycles<=coefficient_cycles+1'b1;
                    // One failed coefficient is sufficient to disprove COPY.
                    // Use the current pipeline result rather than waiting for
                    // mismatch to latch or both entropy streams to finish.
                    // An error on either stream likewise always chooses DATA.
                    if(current_error || reference_error || comparison_failed || comparison_expired ||
                       (current_done && reference_done && !comparison_valid1 && !comparison_valid2)) begin
                        region_safe<=!current_error && !reference_error && !comparison_failed && !comparison_expired && !coefficient_mismatch;
                        copy_group<=!current_error && !reference_error && !comparison_failed && !comparison_expired && !coefficient_mismatch &&
                                    (!frame_adaptive || !local_mismatch);
                        if(!current_error && !reference_error && !comparison_failed && !comparison_expired && !coefficient_mismatch &&
                           (!frame_adaptive || !local_mismatch)) begin
                            prefix<={72'd0,group_index,8'd2};prefix_remaining<=3;
                            state<=GROUP_PREFIX;
                        end else begin
                            prefix<={56'd0,2'd0,group_length,group_index,8'd1};prefix_remaining<=5;
                            state<=WRITE_CMD;
                        end
                        coefficient_current_pending<=0;coefficient_reference_pending<=0;
                        comparison_valid1<=0;comparison_valid2<=0;
                    end
                end
                COMPARE: begin
                    equal_group<=equal_group && group_q==cache_q;
                    if(compare_index==group_length-1) begin
                        copy_group<=equal_group && group_q==cache_q;
                        if(equal_group && group_q==cache_q) begin
                            prefix<={72'd0,group_index,8'd2};prefix_remaining<=3;
                            state<=GROUP_PREFIX;
                        end else begin
                            prefix<={56'd0,2'd0,group_length,group_index,8'd1};prefix_remaining<=5;
                            state<=WRITE_CMD;
                        end
                    end else compare_index<=compare_index+1'b1;
                end
                GROUP_PREFIX: if(out_take) begin
                    prefix<=prefix>>8;prefix_remaining<=prefix_remaining-1'b1;
                    if(prefix_remaining==1 && !copy_group) state<=GROUP_PRIME;
                end
                GROUP_PRIME: begin read_index<=0;state<=GROUP_OUT;end
                GROUP_OUT: if(out_take) begin
                    if(selected && fits && read_index==group_length-1) state<=WRITE_WAIT;
                    read_index<=read_index+1'b1;
                end
                default:state<=HEADER_IN;
            endcase
            if(group_sent) begin
                read_index<=0;write_index<=0;bank_ready[read_bank]<=0;read_bank<=!read_bank;
                if(last_group) begin
                    previous_id<=active_id;reference_valid<=!frame_invalidated && !invalidate;previous_width<=active_width;
                    previous_height<=active_height;previous_gray<=active_gray;
                    previous_threshold<=frame_threshold;
                    previous_adaptive<=frame_adaptive;
                    frames_since_refresh<=keyframe?1:frames_since_refresh+1'b1;
                    group_index<=0;last_group<=0;state<=HEADER_IN;
                end else begin
                    group_index<=group_index+1'b1;state<=GROUP_IN;
                end
            end
            if(invalidate) begin
                reference_valid<=0;frames_since_refresh<=0;
                if(state!=HEADER_IN || write_index!=0) frame_invalidated<=1;
            end
        end
    end
endmodule
