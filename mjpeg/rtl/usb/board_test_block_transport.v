// Board endpoint: legacy internal records -> double-buffered 1024-byte blocks.
// Wire header: "MBLK", type u8, flags u8, body length LE16.
// Types: 0 JPEG (LE32 frame ID + bytes), 1 original descriptor (28B),
// 2 FPS (20B), 3 timing (24B), 4 link counters (28B), 5 END, 6 START.
// JPEG flags: bit0 first, bit1 last, bit2 abort, bits4:3 channel.
// Input is the board's coalesced single-channel stream. EEPROM and the
// portable codec packet protocol remain unchanged.
module board_test_block_transport(
    input clk,rst_n,
    input [7:0] s_data,input s_valid,output s_ready,
    output reg [7:0] m_data,output reg m_valid,input m_ready,
    input stats_valid,input [223:0] stats_data
);
    (* ram_style="block" *) reg [31:0] ram[0:511];
    reg [31:0] ram_q;
    reg [7:0] read_addr;
    reg write_bank,read_bank;
    reg [1:0] bank_ready;
    reg [10:0] bank_length[0:1];
    reg [31:0] bank_id[0:1];
    reg [7:0] bank_flags[0:1];
    reg [8:0] word_count;
    reg [10:0] byte_count;
    reg [31:0] chunk_id;
    reg [7:0] chunk_flags;
    reg [31:0] in_word;
    reg [7:0] in_flag;
    reg [2:0] in_count,packet_index;
    reg in_stream,record_pending,packet_descriptor,packet_first,packet_last;
    reg [4:0] packet_bytes;
    reg [1:0] packet_channel;
    reg [223:0] control_data;
    reg [223:0] descriptor_data;
    reg [7:0] control_type;
    reg [15:0] control_length;
    reg control_pending;
    reg link_pending;
    reg [223:0] link_data;
    localparam OUT_IDLE=0,OUT_HEADER=1,OUT_ID=2,OUT_JPEG=3,OUT_CONTROL=4;
    reg [2:0] out_state;
    reg [63:0] out_header;
    reg [31:0] out_id,out_word;
    reg [223:0] out_control;
    reg [15:0] out_remaining;
    reg [3:0] header_remaining;
    reg [2:0] id_remaining;
    reg [1:0] byte_index;
    reg out_is_jpeg,out_is_link;
    assign s_ready=!record_pending && !control_pending && !bank_ready[write_bank];
    // Keep the RAM ports outside asynchronous-reset control processes.
    // Contents need no reset: a bank becomes visible only after being filled.
    wire ram_write=record_pending && !control_pending && !bank_ready[write_bank] &&
        in_flag[7:4]==0 && packet_index>=2 && !packet_descriptor;
    always @(posedge clk) begin
        if(ram_write) ram[{write_bank,word_count[7:0]}]<=in_word;
        ram_q<=ram[{read_bank,read_addr}];
    end
    always @* begin
        m_valid=out_state!=OUT_IDLE;m_data=0;
        case(out_state)
            OUT_HEADER:m_data=out_header[7:0];
            OUT_ID:m_data=out_id[7:0];
            OUT_JPEG:m_data=out_word[byte_index*8+:8];
            OUT_CONTROL:m_data=out_control[7:0];
            default:m_data=0;
        endcase
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            write_bank<=0;read_bank<=0;bank_ready<=0;word_count<=0;byte_count<=0;
            bank_length[0]<=0;bank_length[1]<=0;bank_id[0]<=0;bank_id[1]<=0;
            bank_flags[0]<=0;bank_flags[1]<=0;chunk_id<=0;chunk_flags<=0;
            in_word<=0;in_flag<=0;in_count<=0;in_stream<=0;record_pending<=0;
            packet_index<=0;packet_descriptor<=0;packet_first<=0;packet_last<=0;
            packet_bytes<=0;packet_channel<=0;control_pending<=0;
            control_data<=0;descriptor_data<=0;control_type<=0;control_length<=0;link_pending<=0;link_data<=0;
            out_state<=OUT_IDLE;out_header<=0;out_id<=0;out_word<=0;
            out_control<=0;out_remaining<=0;header_remaining<=0;id_remaining<=0;
            byte_index<=0;read_addr<=0;out_is_jpeg<=0;out_is_link<=0;
        end else begin
            if(s_valid && s_ready) begin
                if(in_count<4) in_word[in_count*8+:8]<=s_data;
                if(in_count==3 && !in_stream && {s_data,in_word[23:0]}==32'h54424a4d) begin
                    in_stream<=1;in_count<=0;packet_index<=0;
                    control_pending<=1;control_type<=6;control_length<=0;control_data<=0;
                end else if(in_count==4) begin
                    in_flag<=s_data;record_pending<=1;in_count<=0;
                end else in_count<=in_count+1'b1;
            end
            if(record_pending && !control_pending && !bank_ready[write_bank]) begin
                record_pending<=0;
                if(in_flag[7:4]==0) begin
                    if(packet_index==0) begin
                        packet_descriptor<=in_word[11:10]==1;
                        packet_first<=in_word[7];packet_last<=in_word[6];
                        packet_bytes<=in_word[4:0];packet_channel<=in_word[9:8];
                        descriptor_data[31:0]<=in_word;
                    end else if(packet_descriptor) descriptor_data[packet_index*32+:32]<=in_word;
                    else if(packet_index==1) begin
                        chunk_id<=in_word;
                        if(word_count==0) chunk_flags<={3'd0,packet_channel,2'd0,packet_first};
                        if(packet_bytes==0 && in_flag[3]) begin
                            bank_ready[write_bank]<=1;bank_length[write_bank]<=byte_count;
                            bank_id[write_bank]<=in_word;
                            bank_flags[write_bank]<=(word_count==0 ? {3'd0,packet_channel,2'd0,packet_first} : chunk_flags)|8'h06;
                            write_bank<=!write_bank;word_count<=0;byte_count<=0;
                        end
                    end else begin
                        if(word_count==255 || (in_flag[3] && packet_last)) begin
                            bank_ready[write_bank]<=1;
                            bank_length[write_bank]<=byte_count+in_flag[2:0];
                            bank_id[write_bank]<=chunk_id;
                            bank_flags[write_bank]<=chunk_flags|((in_flag[3] && packet_last)?8'h02:8'h00);
                            write_bank<=!write_bank;word_count<=0;byte_count<=0;
                        end else begin word_count<=word_count+1'b1;byte_count<=byte_count+in_flag[2:0];end
                    end
                    packet_index<=in_flag[3] ? 0 : packet_index+1'b1;
                    if(in_flag[3] && packet_descriptor) begin
                        control_pending<=1;control_type<=1;control_length<=28;
                        control_data<={in_word,descriptor_data[191:0]};
                    end
                end else if(in_flag==8'ha0) begin
                    in_stream<=0;control_pending<=1;control_type<=5;control_length<=0;
                end else if(in_flag>=8'h80 && in_flag<=8'h85) begin
                    if(in_flag!=8'h80) control_data[(in_flag-8'h81)*32+:32]<=in_word;
                    if(in_flag==8'h85) begin control_pending<=1;control_type<=2;control_length<=20;end
                end else if(in_flag>=8'h90 && in_flag<=8'h96) begin
                    if(in_flag!=8'h90) control_data[(in_flag-8'h91)*32+:32]<=in_word;
                    if(in_flag==8'h96) begin control_pending<=1;control_type<=3;control_length<=24;end
                end
            end
            if(out_state==OUT_IDLE) begin
                read_addr<=0;
                if(link_pending) begin
                    out_header<={16'd28,8'd0,8'd4,32'h4b4c424d};
                    out_control<=link_data;out_remaining<=28;link_pending<=0;
                    out_is_jpeg<=0;out_is_link<=1;header_remaining<=8;out_state<=OUT_HEADER;
                end else if(bank_ready[read_bank]) begin
                    out_header<={5'd0,(bank_length[read_bank]+11'd4),bank_flags[read_bank],8'd0,32'h4b4c424d};
                    out_id<=bank_id[read_bank];out_remaining<=bank_length[read_bank];
                    out_is_jpeg<=1;out_is_link<=0;header_remaining<=8;out_state<=OUT_HEADER;
                end else if(control_pending && (control_type!=1 || word_count==0)) begin
                    out_header<={control_length,8'd0,control_type,32'h4b4c424d};
                    out_control<=control_data;out_remaining<=control_length;
                    out_is_jpeg<=0;out_is_link<=0;header_remaining<=8;out_state<=OUT_HEADER;
                end
            end else if(m_valid && m_ready) begin
                case(out_state)
                    OUT_HEADER: begin
                        out_header<={8'd0,out_header[63:8]};header_remaining<=header_remaining-1'b1;
                        if(header_remaining==1) begin
                            if(out_is_jpeg) begin id_remaining<=4;out_state<=OUT_ID;end
                            else if(out_remaining!=0) out_state<=OUT_CONTROL;
                            else begin control_pending<=0;out_state<=OUT_IDLE;end
                        end
                    end
                    OUT_ID: begin
                        out_id<={8'd0,out_id[31:8]};id_remaining<=id_remaining-1'b1;
                        if(id_remaining==1) begin
                            out_word<=ram_q;byte_index<=0;read_addr<=1;
                            if(out_remaining==0) begin
                                bank_ready[read_bank]<=0;read_bank<=!read_bank;out_state<=OUT_IDLE;
                            end else out_state<=OUT_JPEG;
                        end
                    end
                    OUT_JPEG: begin
                        out_remaining<=out_remaining-1'b1;byte_index<=byte_index+1'b1;
                        if(byte_index==3) begin out_word<=ram_q;read_addr<=read_addr+1'b1;end
                        if(out_remaining==1) begin
                            bank_ready[read_bank]<=0;read_bank<=!read_bank;out_state<=OUT_IDLE;
                        end
                    end
                    OUT_CONTROL: begin
                        out_control<={8'd0,out_control[223:8]};out_remaining<=out_remaining-1'b1;
                        if(out_remaining==1) begin
                            if(!out_is_link) control_pending<=0;
                            out_state<=OUT_IDLE;
                        end
                    end
                    default:out_state<=OUT_IDLE;
                endcase
            end
            // Retain newest unsent window; the active snapshot is immutable.
            if(stats_valid) begin link_pending<=1;link_data<=stats_data;end
        end
    end
endmodule
