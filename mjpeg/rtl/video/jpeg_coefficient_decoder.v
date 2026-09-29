// Project baseline JPEG entropy to sparse quantized coefficients.
// Four restart MCUs: gray=4 blocks, YUV422=16 blocks. Input includes FF00
// stuffing but excludes the two-byte RST/EOI trailer. start resets DC history.
// Index is block*64+zigzag position; DC is always emitted, AC only if nonzero.
// done/error are sticky until start; done follows the final output handshake.
module jpeg_coefficient_decoder (
    input clk,rst_n,start,gray,
    input [7:0] s_data,input s_valid,output s_ready,input s_last,
    output reg [9:0] m_index,output reg signed [15:0] m_value,
    output reg m_valid,input m_ready,output reg done,error
);
    reg active,gray_latched,ended,stuffing,finishing,ac_phase,amplitude_phase;
    reg [7:0] saved_symbol;
    reg [39:0] reservoir;
    reg [5:0] bit_count;
    reg [3:0] block_index;
    reg [6:0] position;
    reg signed [15:0] previous[0:2];
    wire [1:0] component=gray_latched?2'd0:
        block_index[1:0]==2?2'd1:block_index[1:0]==3?2'd2:2'd0;
    wire [1:0] table_select={component!=0,ac_phase};
    assign s_ready=active && !ended && (stuffing || bit_count<=32);
    function [7:0] symbol_value;
        input [9:0] address;
        begin
            case(address)
                10'h000: symbol_value=8'h00;
                10'h001: symbol_value=8'h01;
                10'h002: symbol_value=8'h02;
                10'h003: symbol_value=8'h03;
                10'h004: symbol_value=8'h04;
                10'h005: symbol_value=8'h05;
                10'h006: symbol_value=8'h06;
                10'h007: symbol_value=8'h07;
                10'h008: symbol_value=8'h08;
                10'h009: symbol_value=8'h09;
                10'h00a: symbol_value=8'h0a;
                10'h00b: symbol_value=8'h0b;
                10'h100: symbol_value=8'h01;
                10'h101: symbol_value=8'h02;
                10'h102: symbol_value=8'h03;
                10'h103: symbol_value=8'h00;
                10'h104: symbol_value=8'h04;
                10'h105: symbol_value=8'h11;
                10'h106: symbol_value=8'h05;
                10'h107: symbol_value=8'h12;
                10'h108: symbol_value=8'h21;
                10'h109: symbol_value=8'h31;
                10'h10a: symbol_value=8'h41;
                10'h10b: symbol_value=8'h06;
                10'h10c: symbol_value=8'h13;
                10'h10d: symbol_value=8'h51;
                10'h10e: symbol_value=8'h61;
                10'h10f: symbol_value=8'h07;
                10'h110: symbol_value=8'h22;
                10'h111: symbol_value=8'h71;
                10'h112: symbol_value=8'h14;
                10'h113: symbol_value=8'h32;
                10'h114: symbol_value=8'h81;
                10'h115: symbol_value=8'h91;
                10'h116: symbol_value=8'ha1;
                10'h117: symbol_value=8'h08;
                10'h118: symbol_value=8'h23;
                10'h119: symbol_value=8'h42;
                10'h11a: symbol_value=8'hb1;
                10'h11b: symbol_value=8'hc1;
                10'h11c: symbol_value=8'h15;
                10'h11d: symbol_value=8'h52;
                10'h11e: symbol_value=8'hd1;
                10'h11f: symbol_value=8'hf0;
                10'h120: symbol_value=8'h24;
                10'h121: symbol_value=8'h33;
                10'h122: symbol_value=8'h62;
                10'h123: symbol_value=8'h72;
                10'h124: symbol_value=8'h82;
                10'h125: symbol_value=8'h09;
                10'h126: symbol_value=8'h0a;
                10'h127: symbol_value=8'h16;
                10'h128: symbol_value=8'h17;
                10'h129: symbol_value=8'h18;
                10'h12a: symbol_value=8'h19;
                10'h12b: symbol_value=8'h1a;
                10'h12c: symbol_value=8'h25;
                10'h12d: symbol_value=8'h26;
                10'h12e: symbol_value=8'h27;
                10'h12f: symbol_value=8'h28;
                10'h130: symbol_value=8'h29;
                10'h131: symbol_value=8'h2a;
                10'h132: symbol_value=8'h34;
                10'h133: symbol_value=8'h35;
                10'h134: symbol_value=8'h36;
                10'h135: symbol_value=8'h37;
                10'h136: symbol_value=8'h38;
                10'h137: symbol_value=8'h39;
                10'h138: symbol_value=8'h3a;
                10'h139: symbol_value=8'h43;
                10'h13a: symbol_value=8'h44;
                10'h13b: symbol_value=8'h45;
                10'h13c: symbol_value=8'h46;
                10'h13d: symbol_value=8'h47;
                10'h13e: symbol_value=8'h48;
                10'h13f: symbol_value=8'h49;
                10'h140: symbol_value=8'h4a;
                10'h141: symbol_value=8'h53;
                10'h142: symbol_value=8'h54;
                10'h143: symbol_value=8'h55;
                10'h144: symbol_value=8'h56;
                10'h145: symbol_value=8'h57;
                10'h146: symbol_value=8'h58;
                10'h147: symbol_value=8'h59;
                10'h148: symbol_value=8'h5a;
                10'h149: symbol_value=8'h63;
                10'h14a: symbol_value=8'h64;
                10'h14b: symbol_value=8'h65;
                10'h14c: symbol_value=8'h66;
                10'h14d: symbol_value=8'h67;
                10'h14e: symbol_value=8'h68;
                10'h14f: symbol_value=8'h69;
                10'h150: symbol_value=8'h6a;
                10'h151: symbol_value=8'h73;
                10'h152: symbol_value=8'h74;
                10'h153: symbol_value=8'h75;
                10'h154: symbol_value=8'h76;
                10'h155: symbol_value=8'h77;
                10'h156: symbol_value=8'h78;
                10'h157: symbol_value=8'h79;
                10'h158: symbol_value=8'h7a;
                10'h159: symbol_value=8'h83;
                10'h15a: symbol_value=8'h84;
                10'h15b: symbol_value=8'h85;
                10'h15c: symbol_value=8'h86;
                10'h15d: symbol_value=8'h87;
                10'h15e: symbol_value=8'h88;
                10'h15f: symbol_value=8'h89;
                10'h160: symbol_value=8'h8a;
                10'h161: symbol_value=8'h92;
                10'h162: symbol_value=8'h93;
                10'h163: symbol_value=8'h94;
                10'h164: symbol_value=8'h95;
                10'h165: symbol_value=8'h96;
                10'h166: symbol_value=8'h97;
                10'h167: symbol_value=8'h98;
                10'h168: symbol_value=8'h99;
                10'h169: symbol_value=8'h9a;
                10'h16a: symbol_value=8'ha2;
                10'h16b: symbol_value=8'ha3;
                10'h16c: symbol_value=8'ha4;
                10'h16d: symbol_value=8'ha5;
                10'h16e: symbol_value=8'ha6;
                10'h16f: symbol_value=8'ha7;
                10'h170: symbol_value=8'ha8;
                10'h171: symbol_value=8'ha9;
                10'h172: symbol_value=8'haa;
                10'h173: symbol_value=8'hb2;
                10'h174: symbol_value=8'hb3;
                10'h175: symbol_value=8'hb4;
                10'h176: symbol_value=8'hb5;
                10'h177: symbol_value=8'hb6;
                10'h178: symbol_value=8'hb7;
                10'h179: symbol_value=8'hb8;
                10'h17a: symbol_value=8'hb9;
                10'h17b: symbol_value=8'hba;
                10'h17c: symbol_value=8'hc2;
                10'h17d: symbol_value=8'hc3;
                10'h17e: symbol_value=8'hc4;
                10'h17f: symbol_value=8'hc5;
                10'h180: symbol_value=8'hc6;
                10'h181: symbol_value=8'hc7;
                10'h182: symbol_value=8'hc8;
                10'h183: symbol_value=8'hc9;
                10'h184: symbol_value=8'hca;
                10'h185: symbol_value=8'hd2;
                10'h186: symbol_value=8'hd3;
                10'h187: symbol_value=8'hd4;
                10'h188: symbol_value=8'hd5;
                10'h189: symbol_value=8'hd6;
                10'h18a: symbol_value=8'hd7;
                10'h18b: symbol_value=8'hd8;
                10'h18c: symbol_value=8'hd9;
                10'h18d: symbol_value=8'hda;
                10'h18e: symbol_value=8'he1;
                10'h18f: symbol_value=8'he2;
                10'h190: symbol_value=8'he3;
                10'h191: symbol_value=8'he4;
                10'h192: symbol_value=8'he5;
                10'h193: symbol_value=8'he6;
                10'h194: symbol_value=8'he7;
                10'h195: symbol_value=8'he8;
                10'h196: symbol_value=8'he9;
                10'h197: symbol_value=8'hea;
                10'h198: symbol_value=8'hf1;
                10'h199: symbol_value=8'hf2;
                10'h19a: symbol_value=8'hf3;
                10'h19b: symbol_value=8'hf4;
                10'h19c: symbol_value=8'hf5;
                10'h19d: symbol_value=8'hf6;
                10'h19e: symbol_value=8'hf7;
                10'h19f: symbol_value=8'hf8;
                10'h1a0: symbol_value=8'hf9;
                10'h1a1: symbol_value=8'hfa;
                10'h200: symbol_value=8'h00;
                10'h201: symbol_value=8'h01;
                10'h202: symbol_value=8'h02;
                10'h203: symbol_value=8'h03;
                10'h204: symbol_value=8'h04;
                10'h205: symbol_value=8'h05;
                10'h206: symbol_value=8'h06;
                10'h207: symbol_value=8'h07;
                10'h208: symbol_value=8'h08;
                10'h209: symbol_value=8'h09;
                10'h20a: symbol_value=8'h0a;
                10'h20b: symbol_value=8'h0b;
                10'h300: symbol_value=8'h00;
                10'h301: symbol_value=8'h01;
                10'h302: symbol_value=8'h02;
                10'h303: symbol_value=8'h03;
                10'h304: symbol_value=8'h11;
                10'h305: symbol_value=8'h04;
                10'h306: symbol_value=8'h05;
                10'h307: symbol_value=8'h21;
                10'h308: symbol_value=8'h31;
                10'h309: symbol_value=8'h06;
                10'h30a: symbol_value=8'h12;
                10'h30b: symbol_value=8'h41;
                10'h30c: symbol_value=8'h51;
                10'h30d: symbol_value=8'h07;
                10'h30e: symbol_value=8'h61;
                10'h30f: symbol_value=8'h71;
                10'h310: symbol_value=8'h13;
                10'h311: symbol_value=8'h22;
                10'h312: symbol_value=8'h32;
                10'h313: symbol_value=8'h81;
                10'h314: symbol_value=8'h08;
                10'h315: symbol_value=8'h14;
                10'h316: symbol_value=8'h42;
                10'h317: symbol_value=8'h91;
                10'h318: symbol_value=8'ha1;
                10'h319: symbol_value=8'hb1;
                10'h31a: symbol_value=8'hc1;
                10'h31b: symbol_value=8'h09;
                10'h31c: symbol_value=8'h23;
                10'h31d: symbol_value=8'h33;
                10'h31e: symbol_value=8'h52;
                10'h31f: symbol_value=8'hf0;
                10'h320: symbol_value=8'h15;
                10'h321: symbol_value=8'h62;
                10'h322: symbol_value=8'h72;
                10'h323: symbol_value=8'hd1;
                10'h324: symbol_value=8'h0a;
                10'h325: symbol_value=8'h16;
                10'h326: symbol_value=8'h24;
                10'h327: symbol_value=8'h34;
                10'h328: symbol_value=8'he1;
                10'h329: symbol_value=8'h25;
                10'h32a: symbol_value=8'hf1;
                10'h32b: symbol_value=8'h17;
                10'h32c: symbol_value=8'h18;
                10'h32d: symbol_value=8'h19;
                10'h32e: symbol_value=8'h1a;
                10'h32f: symbol_value=8'h26;
                10'h330: symbol_value=8'h27;
                10'h331: symbol_value=8'h28;
                10'h332: symbol_value=8'h29;
                10'h333: symbol_value=8'h2a;
                10'h334: symbol_value=8'h35;
                10'h335: symbol_value=8'h36;
                10'h336: symbol_value=8'h37;
                10'h337: symbol_value=8'h38;
                10'h338: symbol_value=8'h39;
                10'h339: symbol_value=8'h3a;
                10'h33a: symbol_value=8'h43;
                10'h33b: symbol_value=8'h44;
                10'h33c: symbol_value=8'h45;
                10'h33d: symbol_value=8'h46;
                10'h33e: symbol_value=8'h47;
                10'h33f: symbol_value=8'h48;
                10'h340: symbol_value=8'h49;
                10'h341: symbol_value=8'h4a;
                10'h342: symbol_value=8'h53;
                10'h343: symbol_value=8'h54;
                10'h344: symbol_value=8'h55;
                10'h345: symbol_value=8'h56;
                10'h346: symbol_value=8'h57;
                10'h347: symbol_value=8'h58;
                10'h348: symbol_value=8'h59;
                10'h349: symbol_value=8'h5a;
                10'h34a: symbol_value=8'h63;
                10'h34b: symbol_value=8'h64;
                10'h34c: symbol_value=8'h65;
                10'h34d: symbol_value=8'h66;
                10'h34e: symbol_value=8'h67;
                10'h34f: symbol_value=8'h68;
                10'h350: symbol_value=8'h69;
                10'h351: symbol_value=8'h6a;
                10'h352: symbol_value=8'h73;
                10'h353: symbol_value=8'h74;
                10'h354: symbol_value=8'h75;
                10'h355: symbol_value=8'h76;
                10'h356: symbol_value=8'h77;
                10'h357: symbol_value=8'h78;
                10'h358: symbol_value=8'h79;
                10'h359: symbol_value=8'h7a;
                10'h35a: symbol_value=8'h82;
                10'h35b: symbol_value=8'h83;
                10'h35c: symbol_value=8'h84;
                10'h35d: symbol_value=8'h85;
                10'h35e: symbol_value=8'h86;
                10'h35f: symbol_value=8'h87;
                10'h360: symbol_value=8'h88;
                10'h361: symbol_value=8'h89;
                10'h362: symbol_value=8'h8a;
                10'h363: symbol_value=8'h92;
                10'h364: symbol_value=8'h93;
                10'h365: symbol_value=8'h94;
                10'h366: symbol_value=8'h95;
                10'h367: symbol_value=8'h96;
                10'h368: symbol_value=8'h97;
                10'h369: symbol_value=8'h98;
                10'h36a: symbol_value=8'h99;
                10'h36b: symbol_value=8'h9a;
                10'h36c: symbol_value=8'ha2;
                10'h36d: symbol_value=8'ha3;
                10'h36e: symbol_value=8'ha4;
                10'h36f: symbol_value=8'ha5;
                10'h370: symbol_value=8'ha6;
                10'h371: symbol_value=8'ha7;
                10'h372: symbol_value=8'ha8;
                10'h373: symbol_value=8'ha9;
                10'h374: symbol_value=8'haa;
                10'h375: symbol_value=8'hb2;
                10'h376: symbol_value=8'hb3;
                10'h377: symbol_value=8'hb4;
                10'h378: symbol_value=8'hb5;
                10'h379: symbol_value=8'hb6;
                10'h37a: symbol_value=8'hb7;
                10'h37b: symbol_value=8'hb8;
                10'h37c: symbol_value=8'hb9;
                10'h37d: symbol_value=8'hba;
                10'h37e: symbol_value=8'hc2;
                10'h37f: symbol_value=8'hc3;
                10'h380: symbol_value=8'hc4;
                10'h381: symbol_value=8'hc5;
                10'h382: symbol_value=8'hc6;
                10'h383: symbol_value=8'hc7;
                10'h384: symbol_value=8'hc8;
                10'h385: symbol_value=8'hc9;
                10'h386: symbol_value=8'hca;
                10'h387: symbol_value=8'hd2;
                10'h388: symbol_value=8'hd3;
                10'h389: symbol_value=8'hd4;
                10'h38a: symbol_value=8'hd5;
                10'h38b: symbol_value=8'hd6;
                10'h38c: symbol_value=8'hd7;
                10'h38d: symbol_value=8'hd8;
                10'h38e: symbol_value=8'hd9;
                10'h38f: symbol_value=8'hda;
                10'h390: symbol_value=8'he2;
                10'h391: symbol_value=8'he3;
                10'h392: symbol_value=8'he4;
                10'h393: symbol_value=8'he5;
                10'h394: symbol_value=8'he6;
                10'h395: symbol_value=8'he7;
                10'h396: symbol_value=8'he8;
                10'h397: symbol_value=8'he9;
                10'h398: symbol_value=8'hea;
                10'h399: symbol_value=8'hf2;
                10'h39a: symbol_value=8'hf3;
                10'h39b: symbol_value=8'hf4;
                10'h39c: symbol_value=8'hf5;
                10'h39d: symbol_value=8'hf6;
                10'h39e: symbol_value=8'hf7;
                10'h39f: symbol_value=8'hf8;
                10'h3a0: symbol_value=8'hf9;
                10'h3a1: symbol_value=8'hfa;
                default: symbol_value=0;
            endcase
        end
    endfunction
    function [13:0] lookup;
        input [1:0] table_id;input [15:0] lookahead;input [5:0] count;
        reg [13:0] result;reg [7:0] value_index;
        begin
            result=0;value_index=0;
            case(table_id)
            2'd0: begin
                if(count>=2 && lookahead>=16'h0000 && lookahead<=16'h3fff) begin
                    result[13]=1;result[12:8]=5'd2;
                    value_index=(lookahead >> 14) + 0;
                end
                if(count>=3 && lookahead>=16'h4000 && lookahead<=16'hdfff) begin
                    result[13]=1;result[12:8]=5'd3;
                    value_index=(lookahead >> 13) + -1;
                end
                if(count>=4 && lookahead>=16'he000 && lookahead<=16'hefff) begin
                    result[13]=1;result[12:8]=5'd4;
                    value_index=(lookahead >> 12) + -8;
                end
                if(count>=5 && lookahead>=16'hf000 && lookahead<=16'hf7ff) begin
                    result[13]=1;result[12:8]=5'd5;
                    value_index=(lookahead >> 11) + -23;
                end
                if(count>=6 && lookahead>=16'hf800 && lookahead<=16'hfbff) begin
                    result[13]=1;result[12:8]=5'd6;
                    value_index=(lookahead >> 10) + -54;
                end
                if(count>=7 && lookahead>=16'hfc00 && lookahead<=16'hfdff) begin
                    result[13]=1;result[12:8]=5'd7;
                    value_index=(lookahead >> 9) + -117;
                end
                if(count>=8 && lookahead>=16'hfe00 && lookahead<=16'hfeff) begin
                    result[13]=1;result[12:8]=5'd8;
                    value_index=(lookahead >> 8) + -244;
                end
                if(count>=9 && lookahead>=16'hff00 && lookahead<=16'hff7f) begin
                    result[13]=1;result[12:8]=5'd9;
                    value_index=(lookahead >> 7) + -499;
                end
            end
            2'd1: begin
                if(count>=2 && lookahead>=16'h0000 && lookahead<=16'h7fff) begin
                    result[13]=1;result[12:8]=5'd2;
                    value_index=(lookahead >> 14) + 0;
                end
                if(count>=3 && lookahead>=16'h8000 && lookahead<=16'h9fff) begin
                    result[13]=1;result[12:8]=5'd3;
                    value_index=(lookahead >> 13) + -2;
                end
                if(count>=4 && lookahead>=16'ha000 && lookahead<=16'hcfff) begin
                    result[13]=1;result[12:8]=5'd4;
                    value_index=(lookahead >> 12) + -7;
                end
                if(count>=5 && lookahead>=16'hd000 && lookahead<=16'he7ff) begin
                    result[13]=1;result[12:8]=5'd5;
                    value_index=(lookahead >> 11) + -20;
                end
                if(count>=6 && lookahead>=16'he800 && lookahead<=16'hefff) begin
                    result[13]=1;result[12:8]=5'd6;
                    value_index=(lookahead >> 10) + -49;
                end
                if(count>=7 && lookahead>=16'hf000 && lookahead<=16'hf7ff) begin
                    result[13]=1;result[12:8]=5'd7;
                    value_index=(lookahead >> 9) + -109;
                end
                if(count>=8 && lookahead>=16'hf800 && lookahead<=16'hfaff) begin
                    result[13]=1;result[12:8]=5'd8;
                    value_index=(lookahead >> 8) + -233;
                end
                if(count>=9 && lookahead>=16'hfb00 && lookahead<=16'hfd7f) begin
                    result[13]=1;result[12:8]=5'd9;
                    value_index=(lookahead >> 7) + -484;
                end
                if(count>=10 && lookahead>=16'hfd80 && lookahead<=16'hfebf) begin
                    result[13]=1;result[12:8]=5'd10;
                    value_index=(lookahead >> 6) + -991;
                end
                if(count>=11 && lookahead>=16'hfec0 && lookahead<=16'hff3f) begin
                    result[13]=1;result[12:8]=5'd11;
                    value_index=(lookahead >> 5) + -2010;
                end
                if(count>=12 && lookahead>=16'hff40 && lookahead<=16'hff7f) begin
                    result[13]=1;result[12:8]=5'd12;
                    value_index=(lookahead >> 4) + -4052;
                end
                if(count>=15 && lookahead>=16'hff80 && lookahead<=16'hff81) begin
                    result[13]=1;result[12:8]=5'd15;
                    value_index=(lookahead >> 1) + -32668;
                end
                if(count>=16 && lookahead>=16'hff82 && lookahead<=16'hfffe) begin
                    result[13]=1;result[12:8]=5'd16;
                    value_index=(lookahead >> 0) + -65373;
                end
            end
            2'd2: begin
                if(count>=2 && lookahead>=16'h0000 && lookahead<=16'hbfff) begin
                    result[13]=1;result[12:8]=5'd2;
                    value_index=(lookahead >> 14) + 0;
                end
                if(count>=3 && lookahead>=16'hc000 && lookahead<=16'hdfff) begin
                    result[13]=1;result[12:8]=5'd3;
                    value_index=(lookahead >> 13) + -3;
                end
                if(count>=4 && lookahead>=16'he000 && lookahead<=16'hefff) begin
                    result[13]=1;result[12:8]=5'd4;
                    value_index=(lookahead >> 12) + -10;
                end
                if(count>=5 && lookahead>=16'hf000 && lookahead<=16'hf7ff) begin
                    result[13]=1;result[12:8]=5'd5;
                    value_index=(lookahead >> 11) + -25;
                end
                if(count>=6 && lookahead>=16'hf800 && lookahead<=16'hfbff) begin
                    result[13]=1;result[12:8]=5'd6;
                    value_index=(lookahead >> 10) + -56;
                end
                if(count>=7 && lookahead>=16'hfc00 && lookahead<=16'hfdff) begin
                    result[13]=1;result[12:8]=5'd7;
                    value_index=(lookahead >> 9) + -119;
                end
                if(count>=8 && lookahead>=16'hfe00 && lookahead<=16'hfeff) begin
                    result[13]=1;result[12:8]=5'd8;
                    value_index=(lookahead >> 8) + -246;
                end
                if(count>=9 && lookahead>=16'hff00 && lookahead<=16'hff7f) begin
                    result[13]=1;result[12:8]=5'd9;
                    value_index=(lookahead >> 7) + -501;
                end
                if(count>=10 && lookahead>=16'hff80 && lookahead<=16'hffbf) begin
                    result[13]=1;result[12:8]=5'd10;
                    value_index=(lookahead >> 6) + -1012;
                end
                if(count>=11 && lookahead>=16'hffc0 && lookahead<=16'hffdf) begin
                    result[13]=1;result[12:8]=5'd11;
                    value_index=(lookahead >> 5) + -2035;
                end
            end
            2'd3: begin
                if(count>=2 && lookahead>=16'h0000 && lookahead<=16'h7fff) begin
                    result[13]=1;result[12:8]=5'd2;
                    value_index=(lookahead >> 14) + 0;
                end
                if(count>=3 && lookahead>=16'h8000 && lookahead<=16'h9fff) begin
                    result[13]=1;result[12:8]=5'd3;
                    value_index=(lookahead >> 13) + -2;
                end
                if(count>=4 && lookahead>=16'ha000 && lookahead<=16'hbfff) begin
                    result[13]=1;result[12:8]=5'd4;
                    value_index=(lookahead >> 12) + -7;
                end
                if(count>=5 && lookahead>=16'hc000 && lookahead<=16'hdfff) begin
                    result[13]=1;result[12:8]=5'd5;
                    value_index=(lookahead >> 11) + -19;
                end
                if(count>=6 && lookahead>=16'he000 && lookahead<=16'hefff) begin
                    result[13]=1;result[12:8]=5'd6;
                    value_index=(lookahead >> 10) + -47;
                end
                if(count>=7 && lookahead>=16'hf000 && lookahead<=16'hf5ff) begin
                    result[13]=1;result[12:8]=5'd7;
                    value_index=(lookahead >> 9) + -107;
                end
                if(count>=8 && lookahead>=16'hf600 && lookahead<=16'hf9ff) begin
                    result[13]=1;result[12:8]=5'd8;
                    value_index=(lookahead >> 8) + -230;
                end
                if(count>=9 && lookahead>=16'hfa00 && lookahead<=16'hfd7f) begin
                    result[13]=1;result[12:8]=5'd9;
                    value_index=(lookahead >> 7) + -480;
                end
                if(count>=10 && lookahead>=16'hfd80 && lookahead<=16'hfebf) begin
                    result[13]=1;result[12:8]=5'd10;
                    value_index=(lookahead >> 6) + -987;
                end
                if(count>=11 && lookahead>=16'hfec0 && lookahead<=16'hff3f) begin
                    result[13]=1;result[12:8]=5'd11;
                    value_index=(lookahead >> 5) + -2006;
                end
                if(count>=12 && lookahead>=16'hff40 && lookahead<=16'hff7f) begin
                    result[13]=1;result[12:8]=5'd12;
                    value_index=(lookahead >> 4) + -4048;
                end
                if(count>=14 && lookahead>=16'hff80 && lookahead<=16'hff83) begin
                    result[13]=1;result[12:8]=5'd14;
                    value_index=(lookahead >> 2) + -16312;
                end
                if(count>=15 && lookahead>=16'hff84 && lookahead<=16'hff87) begin
                    result[13]=1;result[12:8]=5'd15;
                    value_index=(lookahead >> 1) + -32665;
                end
                if(count>=16 && lookahead>=16'hff88 && lookahead<=16'hfffe) begin
                    result[13]=1;result[12:8]=5'd16;
                    value_index=(lookahead >> 0) + -65373;
                end
            end
            endcase
            if(result[13]) result[7:0]=symbol_value({table_id,value_index});
            lookup=result;
        end
    endfunction
    wire [13:0] decoded=lookup(table_select,reservoir[39:24],bit_count);
    wire [4:0] code_length=decoded[12:8];
    wire [7:0] symbol=decoded[7:0];
    wire [3:0] amplitude_length=saved_symbol[3:0];
    wire special=ac_phase && (symbol==0 || symbol==8'hf0);
    wire output_available=!m_valid || m_ready;
    wire can_huffman=active && !finishing && !amplitude_phase && output_available && decoded[13];
    wire can_amplitude=active && !finishing && amplitude_phase && output_available &&
        bit_count>=amplitude_length;
    wire [5:0] consume_count=can_huffman?{1'b0,code_length}:{2'd0,amplitude_length};
    reg [39:0] next_reservoir;
    reg [5:0] next_count;
    reg [15:0] amplitude;
    reg signed [16:0] signed_amplitude,dc_value;
    reg [7:0] coefficient_position;
    always @* begin
        amplitude=reservoir >> (40-amplitude_length);
        signed_amplitude=amplitude;
        // JPEG negative amplitudes are one's-complement within their category.
        // Sign-extend then add one; avoid a magnitude comparator and two subtractors.
        if(amplitude_length==0) signed_amplitude=0;
        else if(!amplitude[amplitude_length-1])
            signed_amplitude=$signed({1'b1,(amplitude | (16'hffff << amplitude_length))})+17'sd1;
        dc_value=$signed(previous[component])+signed_amplitude;
        coefficient_position={1'b0,position}+{4'd0,saved_symbol[7:4]};
        next_reservoir=reservoir;
        next_count=bit_count;
        // An accepted byte begins immediately after the old valid bits.
        // Insert using registered bit_count, then consume from the combined word.
        // Consumption is bounded by old bit_count, so no inserted bit is lost.
        // This removes subtract -> variable right shift from the feedback path.
        if(s_valid && s_ready && !stuffing)
            next_reservoir=reservoir | ({s_data,32'd0} >> bit_count);
        if(can_huffman || can_amplitude) begin
            next_reservoir=next_reservoir << consume_count;next_count=bit_count-consume_count;
        end
        if(s_valid && s_ready && !stuffing) next_count=next_count+8;
    end
    task advance_block;
        begin
            if(block_index==(gray_latched?3:15)) finishing<=1;
            else begin block_index<=block_index+1'b1;position<=0;ac_phase<=0;end
        end
    endtask
    always @(posedge clk) begin
        if(!rst_n || start) begin
            active<=rst_n && start;gray_latched<=gray;ended<=0;stuffing<=0;
            finishing<=0;ac_phase<=0;amplitude_phase<=0;saved_symbol<=0;
            reservoir<=0;bit_count<=0;block_index<=0;
            position<=0;previous[0]<=0;previous[1]<=0;previous[2]<=0;
            m_index<=0;m_value<=0;m_valid<=0;done<=0;error<=0;
        end else if(active) begin
            reservoir<=next_reservoir;bit_count<=next_count;
            if(m_valid && m_ready) m_valid<=0;
            if(s_valid && s_ready) begin
                if(stuffing) begin
                    stuffing<=0;
                    if(s_data!=0) begin error<=1;done<=1;active<=0;end
                end else stuffing<=s_data==8'hff;
                if(s_last) ended<=1;
            end
            if(can_huffman) begin
                if(!ac_phase) begin
                    if(symbol>11) begin error<=1;done<=1;active<=0;end
                    else begin saved_symbol<=symbol;amplitude_phase<=1;end
                end else if(symbol==0) advance_block;
                else if(symbol==8'hf0) begin
                    if(position+16>64) begin error<=1;done<=1;active<=0;end
                    else if(position+16==64) advance_block;
                    else position<=position+16;
                end else if(symbol[3:0]==0 || symbol[3:0]>10 || position+symbol[7:4]>=64) begin
                    error<=1;done<=1;active<=0;
                end else begin saved_symbol<=symbol;amplitude_phase<=1;end
            end else if(can_amplitude) begin
                amplitude_phase<=0;
                if(!ac_phase) begin
                    // At most eight Y DC differences per four-MCU group.
                    // Accepted category<=11 bounds |DC|<=8*2047<32768.
                    m_index<={block_index,6'd0};m_value<=dc_value[15:0];m_valid<=1;
                    previous[component]<=dc_value[15:0];ac_phase<=1;position<=1;
                end else begin
                    m_index<={block_index,coefficient_position[5:0]};m_value<=signed_amplitude[15:0];m_valid<=1;
                    if(coefficient_position==63) advance_block;
                    else position<=coefficient_position+1'b1;
                end
            end else if(!finishing && output_available) begin
                if(!amplitude_phase && ((bit_count>=16 && !decoded[13]) || (ended && !decoded[13])) ||
                   amplitude_phase && ended && bit_count<amplitude_length) begin
                    error<=1;done<=1;active<=0;
                end
            end
            if(finishing && ended && output_available) begin
                // JPEG pads each restart interval with 0..7 one bits.
                done<=1;active<=0;
                if(stuffing || bit_count>7 ||
                   (reservoir | (40'hffffffffff >> bit_count))!=40'hffffffffff) error<=1;
            end
            // Extra entropy cannot become valid padding. Reject before a long
            // malformed suffix fills the reservoir and backpressures s_last.
            if(finishing && output_available && bit_count>7) begin
                error<=1;done<=1;active<=0;
            end
        end
    end
endmodule
