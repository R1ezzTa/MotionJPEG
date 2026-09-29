`timescale 1ns/1ps
// Register values based on the local ALIENTEK DaVinci 39_ov5640_lcd example
// (i2c_ov5640_rgb565_cfg.v), with DVP VGA YUV422 changes verified against
// OmniVision OV5640 CSP3 datasheet v2.01. Compatible module has a 24 MHz XCLK.
// 4300=30 emits Y0 U0 Y1 V0 (YUYV), 501f=00 selects ISP YUV422.
// 4740=20: rising PCLK sampling, HREF high during valid pixels and VSYNC
// high during frame sync. Bit1=1 selects horizontal blanking on this module:
// hardware counted 982400 blank bytes/frame instead of 614400 image bytes.
// VGA baseline: HTS=1600, VTS=1000, PLL sys divider=2 (~15fps).
// Static HD/FHD/RAW profiles below must be verified by physical VSYNC counts.
module ov5640_init #(
    parameter integer CAMERA_PROFILE=0,
    parameter integer CLK_HZ=100000000,
    parameter integer SCCB_HZ=100000,
    parameter integer POWER_DELAY_MS=5,
    parameter integer RESET_DELAY_MS=20,
    parameter integer SOFT_RESET_DELAY_MS=10,
    parameter integer SETTLE_DELAY_MS=50,
    parameter integer RETRY_LIMIT=2,
    parameter integer LIGHT_MAX_MS=2000
)(
    input wire clk, input wire rst_n,
    input wire light_start, input wire light_cancel,
    output reg light_requested, output reg light_on, output reg light_error,
    output wire light_busy,
    output reg cam_rst_n, output reg cam_pwdn,
    output wire cam_scl,
    input wire cam_sda_i, output wire cam_sda_drive_low,
    output reg init_done, output reg init_error,
    output reg [7:0] init_error_code,
    output reg [15:0] chip_id,
    output reg [8:0] reg_index,
    output reg [15:0] ack_error_count,
    output reg [15:0] last_reg_addr
);
    localparam integer ROM_COUNT=260+((CAMERA_PROFILE>=4)?2:0);
    localparam integer END_INDEX=ROM_COUNT+10+((CAMERA_PROFILE>=1)?7:0)+((CAMERA_PROFILE>=4)?4:0);
    localparam POWER=0, RELEASE_PWDN=1, RELEASE_RESET=2, ISSUE=3,
               WAIT_BUS=4, DELAY=5, COMPLETE=6, FAILED=7,
               LIGHT_ISSUE=8, LIGHT_WAIT=9, LIGHT_READ=10, LIGHT_VERIFY=11;
    reg [3:0] state, delay_next;
    reg [31:0] wait_count, wait_limit;
    reg [2:0] retries;
    reg bus_start;
    wire bus_busy,bus_done,bus_ack_error;
    wire [7:0] bus_read_data;
    reg [23:0] command;
    reg read_command;
    reg [7:0] expected_data;
    reg check_data;
    reg light_target;
    reg [31:0] light_elapsed;
    assign light_busy=(state==LIGHT_ISSUE || state==LIGHT_WAIT ||
                       state==LIGHT_READ || state==LIGHT_VERIFY);
    wire [8:0] rom_index = reg_index-9'd2;
    // 0 VGA15, 1 VGA30, 2 HD15, 3 HD30, 4 FHD15 YUYV, 5 FHD30 RAW8.
    // HD15 keeps its validated 672MHz VCO / 42MHz DVP. Faster profiles
    // use 24MHz / 4 * 100 = 600MHz VCO, 75MHz DVP and shorter blanking.
    // RAW8 fits 1080p30; full-resolution YUYV cannot fit 1080p30.
    localparam [15:0] PROFILE_WIDTH=(CAMERA_PROFILE>=4)?1920:(CAMERA_PROFILE>=2)?1280:640;
    localparam [15:0] PROFILE_HEIGHT=(CAMERA_PROFILE>=4)?1080:(CAMERA_PROFILE>=2)?720:480;
    localparam [15:0] PROFILE_HTS=(CAMERA_PROFILE>=4)?2240:(CAMERA_PROFILE==3)?1690:(CAMERA_PROFILE==2)?1896:1600;
    localparam [15:0] PROFILE_VTS=(CAMERA_PROFILE>=4)?1116:(CAMERA_PROFILE>=2)?740:1000;
    localparam [7:0] PROFILE_SYS=(CAMERA_PROFILE==2)?8'h41:(CAMERA_PROFILE==3 || CAMERA_PROFILE==4 || CAMERA_PROFILE==0)?8'h21:8'h11;
    localparam [7:0] PROFILE_MULT=(CAMERA_PROFILE>=3)?8'h64:(CAMERA_PROFILE==2)?8'h70:8'h3c;
    localparam [7:0] PROFILE_BITS=(CAMERA_PROFILE>=2)?8'h18:8'h1a;
    localparam [7:0] PROFILE_PDIV=(CAMERA_PROFILE>=2 && CAMERA_PROFILE<=4)?1:2;
    localparam [15:0] BAND50=(CAMERA_PROFILE==5)?334:(CAMERA_PROFILE==4)?167:(CAMERA_PROFILE==3)?221:(CAMERA_PROFILE==2)?110:(CAMERA_PROFILE==1)?300:150;
    localparam [15:0] BAND60=(CAMERA_PROFILE==5)?279:(CAMERA_PROFILE==4)?139:(CAMERA_PROFILE==3)?184:(CAMERA_PROFILE==2)?92:(CAMERA_PROFILE==1)?250:125;
    function [23:0] config_word;
        input [8:0] index;
        begin
            case(index)
                9'd0: config_word=24'h300882;
                9'd1: config_word=24'h300842;
                9'd2: config_word=24'h310302;
                9'd3: config_word=24'h3017ff;
                9'd4: config_word=24'h3018ff;
                9'd5: config_word=24'h303713;
                9'd6: config_word=24'h310801;
                9'd7: config_word=24'h363036;
                9'd8: config_word=24'h36310e;
                9'd9: config_word=24'h3632e2;
                9'd10: config_word=24'h363312;
                9'd11: config_word=24'h3621e0;
                9'd12: config_word=24'h3704a0;
                9'd13: config_word=24'h37035a;
                9'd14: config_word=24'h371578;
                9'd15: config_word=24'h371701;
                9'd16: config_word=24'h370b60;
                9'd17: config_word=24'h37051a;
                9'd18: config_word=24'h390502;
                9'd19: config_word=24'h390610;
                9'd20: config_word=24'h39010a;
                9'd21: config_word=24'h373112;
                9'd22: config_word=24'h360008;
                9'd23: config_word=24'h360133;
                9'd24: config_word=24'h302d60;
                9'd25: config_word=24'h362052;
                9'd26: config_word=24'h371b20;
                9'd27: config_word=24'h471c50;
                9'd28: config_word=24'h3a1343;
                9'd29: config_word=24'h3a1800;
                9'd30: config_word=24'h3a19f8;
                9'd31: config_word=24'h363513;
                9'd32: config_word=24'h363603;
                9'd33: config_word=24'h363440;
                9'd34: config_word=24'h362201;
                9'd35: config_word=24'h3c0134;
                9'd36: config_word=24'h3c0428;
                9'd37: config_word=24'h3c0598;
                9'd38: config_word=24'h3c0600;
                9'd39: config_word=24'h3c0708;
                9'd40: config_word=24'h3c0800;
                9'd41: config_word=24'h3c091c;
                9'd42: config_word=24'h3c0a9c;
                9'd43: config_word=24'h3c0b40;
                9'd44: config_word=24'h381000;
                9'd45: config_word=24'h381110;
                9'd46: config_word=24'h381200;
                9'd47: config_word=24'h370864;
                9'd48: config_word=24'h400102;
                9'd49: config_word=24'h40051a;
                9'd50: config_word=24'h300000;
                9'd51: config_word=24'h3004ff;
                9'd52: config_word=24'h430030;
                9'd53: config_word=24'h501f00;
                9'd54: config_word=24'h440e00;
                9'd55: config_word=24'h5000a7;
                9'd56: config_word=24'h3a0f30;
                9'd57: config_word=24'h3a1028;
                9'd58: config_word=24'h3a1b30;
                9'd59: config_word=24'h3a1e26;
                9'd60: config_word=24'h3a1160;
                9'd61: config_word=24'h3a1f14;
                9'd62: config_word=24'h580023;
                9'd63: config_word=24'h580114;
                9'd64: config_word=24'h58020f;
                9'd65: config_word=24'h58030f;
                9'd66: config_word=24'h580412;
                9'd67: config_word=24'h580526;
                9'd68: config_word=24'h58060c;
                9'd69: config_word=24'h580708;
                9'd70: config_word=24'h580805;
                9'd71: config_word=24'h580905;
                9'd72: config_word=24'h580a08;
                9'd73: config_word=24'h580b0d;
                9'd74: config_word=24'h580c08;
                9'd75: config_word=24'h580d03;
                9'd76: config_word=24'h580e00;
                9'd77: config_word=24'h580f00;
                9'd78: config_word=24'h581003;
                9'd79: config_word=24'h581109;
                9'd80: config_word=24'h581207;
                9'd81: config_word=24'h581303;
                9'd82: config_word=24'h581400;
                9'd83: config_word=24'h581501;
                9'd84: config_word=24'h581603;
                9'd85: config_word=24'h581708;
                9'd86: config_word=24'h58180d;
                9'd87: config_word=24'h581908;
                9'd88: config_word=24'h581a05;
                9'd89: config_word=24'h581b06;
                9'd90: config_word=24'h581c08;
                9'd91: config_word=24'h581d0e;
                9'd92: config_word=24'h581e29;
                9'd93: config_word=24'h581f17;
                9'd94: config_word=24'h582011;
                9'd95: config_word=24'h582111;
                9'd96: config_word=24'h582215;
                9'd97: config_word=24'h582328;
                9'd98: config_word=24'h582446;
                9'd99: config_word=24'h582526;
                9'd100: config_word=24'h582608;
                9'd101: config_word=24'h582726;
                9'd102: config_word=24'h582864;
                9'd103: config_word=24'h582926;
                9'd104: config_word=24'h582a24;
                9'd105: config_word=24'h582b22;
                9'd106: config_word=24'h582c24;
                9'd107: config_word=24'h582d24;
                9'd108: config_word=24'h582e06;
                9'd109: config_word=24'h582f22;
                9'd110: config_word=24'h583040;
                9'd111: config_word=24'h583142;
                9'd112: config_word=24'h583224;
                9'd113: config_word=24'h583326;
                9'd114: config_word=24'h583424;
                9'd115: config_word=24'h583522;
                9'd116: config_word=24'h583622;
                9'd117: config_word=24'h583726;
                9'd118: config_word=24'h583844;
                9'd119: config_word=24'h583924;
                9'd120: config_word=24'h583a26;
                9'd121: config_word=24'h583b28;
                9'd122: config_word=24'h583c42;
                9'd123: config_word=24'h583dce;
                9'd124: config_word=24'h5180ff;
                9'd125: config_word=24'h5181f2;
                9'd126: config_word=24'h518200;
                9'd127: config_word=24'h518314;
                9'd128: config_word=24'h518425;
                9'd129: config_word=24'h518524;
                9'd130: config_word=24'h518609;
                9'd131: config_word=24'h518709;
                9'd132: config_word=24'h518809;
                9'd133: config_word=24'h518975;
                9'd134: config_word=24'h518a54;
                9'd135: config_word=24'h518be0;
                9'd136: config_word=24'h518cb2;
                9'd137: config_word=24'h518d42;
                9'd138: config_word=24'h518e3d;
                9'd139: config_word=24'h518f56;
                9'd140: config_word=24'h519046;
                9'd141: config_word=24'h5191f8;
                9'd142: config_word=24'h519204;
                9'd143: config_word=24'h519370;
                9'd144: config_word=24'h5194f0;
                9'd145: config_word=24'h5195f0;
                9'd146: config_word=24'h519603;
                9'd147: config_word=24'h519701;
                9'd148: config_word=24'h519804;
                9'd149: config_word=24'h519912;
                9'd150: config_word=24'h519a04;
                9'd151: config_word=24'h519b00;
                9'd152: config_word=24'h519c06;
                9'd153: config_word=24'h519d82;
                9'd154: config_word=24'h519e38;
                9'd155: config_word=24'h548001;
                9'd156: config_word=24'h548108;
                9'd157: config_word=24'h548214;
                9'd158: config_word=24'h548328;
                9'd159: config_word=24'h548451;
                9'd160: config_word=24'h548565;
                9'd161: config_word=24'h548671;
                9'd162: config_word=24'h54877d;
                9'd163: config_word=24'h548887;
                9'd164: config_word=24'h548991;
                9'd165: config_word=24'h548a9a;
                9'd166: config_word=24'h548baa;
                9'd167: config_word=24'h548cb8;
                9'd168: config_word=24'h548dcd;
                9'd169: config_word=24'h548edd;
                9'd170: config_word=24'h548fea;
                9'd171: config_word=24'h54901d;
                9'd172: config_word=24'h53811e;
                9'd173: config_word=24'h53825b;
                9'd174: config_word=24'h538308;
                9'd175: config_word=24'h53840a;
                9'd176: config_word=24'h53857e;
                9'd177: config_word=24'h538688;
                9'd178: config_word=24'h53877c;
                9'd179: config_word=24'h53886c;
                9'd180: config_word=24'h538910;
                9'd181: config_word=24'h538a01;
                9'd182: config_word=24'h538b98;
                9'd183: config_word=24'h558006;
                9'd184: config_word=24'h558340;
                9'd185: config_word=24'h558410;
                9'd186: config_word=24'h558910;
                9'd187: config_word=24'h558a00;
                9'd188: config_word=24'h558bf8;
                9'd189: config_word=24'h501d40;
                9'd190: config_word=24'h530008;
                9'd191: config_word=24'h530130;
                9'd192: config_word=24'h530210;
                9'd193: config_word=24'h530300;
                9'd194: config_word=24'h530408;
                9'd195: config_word=24'h530530;
                9'd196: config_word=24'h530608;
                9'd197: config_word=24'h530716;
                9'd198: config_word=24'h530908;
                9'd199: config_word=24'h530a30;
                9'd200: config_word=24'h530b04;
                9'd201: config_word=24'h530c06;
                9'd202: config_word=24'h502500;
                9'd203: config_word=24'h303521;
                9'd204: config_word=24'h30363c;
                9'd205: config_word=24'h3c0708;
                9'd206: config_word=24'h382046;
                9'd207: config_word=24'h382101;
                9'd208: config_word=24'h381431;
                9'd209: config_word=24'h381531;
                9'd210: config_word=24'h380000;
                9'd211: config_word=24'h380100;
                9'd212: config_word=24'h380200;
                9'd213: config_word=24'h380304;
                9'd214: config_word=24'h38040a;
                9'd215: config_word=24'h38053f;
                9'd216: config_word=24'h380607;
                9'd217: config_word=24'h38079b;
                9'd218: config_word=24'h380802;
                9'd219: config_word=24'h380980;
                9'd220: config_word=24'h380a01;
                9'd221: config_word=24'h380be0;
                9'd222: config_word=24'h380c06;
                9'd223: config_word=24'h380d40;
                9'd224: config_word=24'h380e03;
                9'd225: config_word=24'h380fe8;
                9'd226: config_word=24'h381306;
                9'd227: config_word=24'h361800;
                9'd228: config_word=24'h361229;
                9'd229: config_word=24'h370952;
                9'd230: config_word=24'h370c03;
                9'd231: config_word=24'h3a0203;
                9'd232: config_word=24'h3a03e8;
                9'd233: config_word=24'h3a1403;
                9'd234: config_word=24'h3a15e8;
                9'd235: config_word=24'h400402;
                9'd236: config_word=24'h471303;
                9'd237: config_word=24'h440704;
                9'd238: config_word=24'h460c22;
                9'd239: config_word=24'h483722;
                9'd240: config_word=24'h382402;
                9'd241: config_word=24'h5001a3;
                9'd242: config_word=24'h3b070a;
                9'd243: config_word=24'h503d00;
                9'd244: config_word=24'h301602;
                9'd245: config_word=24'h301c02;
                9'd246: config_word=24'h301900; // no unsolicited startup flash
                9'd247: config_word=24'h301900;
                9'd248: config_word=24'h30341a;
                9'd249: config_word=24'h300e58;
                9'd250: config_word=24'h460b35;
                9'd251: config_word=24'h474020;
                9'd252: config_word=24'h430100;
                9'd253: config_word=24'h3a0800;
                9'd254: config_word=24'h3a0980;
                9'd255: config_word=24'h3a0a00;
                9'd256: config_word=24'h3a0b6b;
                9'd257: config_word=24'h3a0d09;
                9'd258: config_word=24'h3a0e07;
                9'd259: config_word=24'h300802;
                // Espressif OV5640 set_image_options: unbinned + vflip.
                9'd260: config_word=24'h451400;
                9'd261: config_word=24'h452010;
                default: config_word=24'h300802;
            endcase
            if(CAMERA_PROFILE>=1) begin
                case(config_word[23:8])
                    16'h3035: config_word[7:0]=PROFILE_SYS;
                    16'h3036: config_word[7:0]=PROFILE_MULT;
                    16'h3034: config_word[7:0]=PROFILE_BITS;
                    16'h3808: config_word[7:0]=PROFILE_WIDTH[15:8];
                    16'h3809: config_word[7:0]=PROFILE_WIDTH[7:0];
                    16'h380a: config_word[7:0]=PROFILE_HEIGHT[15:8];
                    16'h380b: config_word[7:0]=PROFILE_HEIGHT[7:0];
                    16'h380c: config_word[7:0]=PROFILE_HTS[15:8];
                    16'h380d: config_word[7:0]=PROFILE_HTS[7:0];
                    16'h380e,16'h3a02,16'h3a14: config_word[7:0]=PROFILE_VTS[15:8];
                    16'h380f,16'h3a03,16'h3a15: config_word[7:0]=PROFILE_VTS[7:0];
                    16'h3824: config_word[7:0]=PROFILE_PDIV;
                    16'h3a08: config_word[7:0]=BAND50[15:8];
                    16'h3a09: config_word[7:0]=BAND50[7:0];
                    16'h3a0a: config_word[7:0]=BAND60[15:8];
                    16'h3a0b: config_word[7:0]=BAND60[7:0];
                    16'h3a0d: config_word[7:0]=(PROFILE_VTS-4)/BAND60;
                    16'h3a0e: config_word[7:0]=(PROFILE_VTS-4)/BAND50;
                endcase
            end
            if(CAMERA_PROFILE>=2) begin
                case(config_word[23:8])
                    16'h3037: config_word[7:0]=8'h14;
                    16'h3800: config_word[7:0]=(CAMERA_PROFILE>=4)?8'h01:8'h00;
                    16'h3801: config_word[7:0]=(CAMERA_PROFILE>=4)?8'h50:8'h00;
                    16'h3802: config_word[7:0]=(CAMERA_PROFILE>=4)?8'h01:8'h00;
                    16'h3803: config_word[7:0]=(CAMERA_PROFILE>=4)?8'hb2:8'hfa;
                    16'h3804: config_word[7:0]=(CAMERA_PROFILE>=4)?8'h08:8'h0a;
                    16'h3805: config_word[7:0]=(CAMERA_PROFILE>=4)?8'hef:8'h3f;
                    16'h3806: config_word[7:0]=(CAMERA_PROFILE>=4)?8'h05:8'h06;
                    16'h3807: config_word[7:0]=(CAMERA_PROFILE>=4)?8'hf2:8'ha9;
                    16'h3813: config_word[7:0]=8'h04;
                    16'h3814,16'h3815: config_word[7:0]=(CAMERA_PROFILE>=4)?8'h11:8'h31;
                    // Preserve the verified module orientation in HD/FHD.
                    // Both ISP/sensor vertical flip bits match VGA (46).
                    16'h3820: config_word[7:0]=(CAMERA_PROFILE>=4)?8'h46:8'h47;
                    // Unbinned FHD must disable horizontal binning too.
                    16'h3821: config_word[7:0]=(CAMERA_PROFILE>=4)?8'h00:8'h01;
                    16'h3618: config_word[7:0]=(CAMERA_PROFILE>=4)?8'h04:8'h00;
                    16'h3612: config_word[7:0]=(CAMERA_PROFILE>=4)?8'h2b:8'h29;
                    16'h3709: config_word[7:0]=(CAMERA_PROFILE>=4)?8'h12:8'h52;
                    16'h370c: config_word[7:0]=(CAMERA_PROFILE>=4)?8'h00:8'h03;
                    16'h4004: config_word[7:0]=(CAMERA_PROFILE>=4)?8'h06:8'h02;
                    16'h5001: config_word[7:0]=8'h83;
                endcase
            end
            if(CAMERA_PROFILE==5) begin
                case(config_word[23:8])
                    16'h4300: config_word[7:0]=8'h00; // BGGR8
                    16'h501f: config_word[7:0]=8'h03; // RAW after DPC
                    // Profile-5 RAW needs BGGR ISP channel assignment. With
                    // 46 the sensor image is unchanged but ISP gains/bars map
                    // as GRBG, producing green with BGGR and purple with GRBG.
                    // 42 keeps sensor vflip, clears ISP vflip; RAW and ISP
                    // match. Verified by optical RAW, gains and colour bars.
                    16'h3820: config_word[7:0]=8'h42;
                endcase
            end
        end
    endfunction
    always @* begin
        command=config_word(rom_index); read_command=0;
        expected_data=0; check_data=0;
        if(reg_index==0) begin command=24'h300a00; read_command=1; expected_data=8'h56; check_data=1; end
        else if(reg_index==1) begin command=24'h300b00; read_command=1; expected_data=8'h40; check_data=1; end
        else if(reg_index>=ROM_COUNT+2) begin
            read_command=1; check_data=1;
            case(reg_index-(ROM_COUNT+2))
                0: begin command=24'h430000; expected_data=(CAMERA_PROFILE==5)?8'h00:8'h30; end
                1: begin command=24'h501f00; expected_data=(CAMERA_PROFILE==5)?8'h03:8'h00; end
                2: begin command=24'h380800; expected_data=PROFILE_WIDTH[15:8]; end
                3: begin command=24'h380900; expected_data=PROFILE_WIDTH[7:0]; end
                4: begin command=24'h380a00; expected_data=PROFILE_HEIGHT[15:8]; end
                5: begin command=24'h380b00; expected_data=PROFILE_HEIGHT[7:0]; end
                6: begin command=24'h303400; expected_data=PROFILE_BITS; end
                7: begin command=24'h300800; expected_data=8'h02; end
                8: begin command=24'h474000; expected_data=8'h20; end
                9: begin command=24'h380e00; expected_data=PROFILE_VTS[15:8]; end
                10: begin command=24'h380f00; expected_data=PROFILE_VTS[7:0]; end
                11: begin command=24'h303500; expected_data=PROFILE_SYS; end
                12: begin command=24'h303600; expected_data=PROFILE_MULT; end
                13: begin command=24'h380c00; expected_data=PROFILE_HTS[15:8]; end
                14: begin command=24'h380d00; expected_data=PROFILE_HTS[7:0]; end
                15: begin command=24'h382400; expected_data=PROFILE_PDIV; end
                16: begin command=24'h382000; expected_data=(CAMERA_PROFILE==5)?8'h42:8'h46; end
                17: begin command=24'h382100; expected_data=8'h00; end
                18: begin command=24'h451400; expected_data=8'h00; end
                19: begin command=24'h452000; expected_data=8'h10; end
                default: begin command=24'h300a00; check_data=0; end
            endcase
        end
        // Initialization already selects STROBE GPIO (3016/301c=02), and
        // leaves it off (3019=00). Runtime writes change only this output.
        if(state==LIGHT_ISSUE || state==LIGHT_WAIT) begin
            command={16'h3019,6'd0,light_target,1'b0};
            read_command=0;check_data=0;
        end else if(state==LIGHT_READ || state==LIGHT_VERIFY) begin
            command=24'h301900;read_command=1;check_data=1;
            expected_data={6'd0,light_target,1'b0};
        end
    end
    ov5640_sccb_master #(.CLK_HZ(CLK_HZ),.SCCB_HZ(SCCB_HZ)) u_sccb (
        .clk(clk),.rst_n(rst_n),.start(bus_start),.read_not_write(read_command),
        .reg_addr(command[23:8]),.write_data(command[7:0]),
        .busy(bus_busy),.done(bus_done),.ack_error(bus_ack_error),
        .read_data(bus_read_data),.scl(cam_scl),
        .sda_i(cam_sda_i),.sda_drive_low(cam_sda_drive_low)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=POWER; delay_next<=ISSUE; wait_count<=0; wait_limit<=0;
            retries<=0; bus_start<=0; cam_rst_n<=0; cam_pwdn<=1;
            init_done<=0; init_error<=0; init_error_code<=0; chip_id<=0;
            reg_index<=0; ack_error_count<=0; last_reg_addr<=0;
            light_requested<=0;light_on<=0;light_error<=0;
            light_target<=0;light_elapsed<=0;
        end else begin
            bus_start<=0;
            // Independent of USB/host software: every request expires after
            // LIGHT_MAX_MS. S/l cancellation has priority over a new request.
            if(light_cancel) begin light_requested<=0;light_elapsed<=0;end
            else if(light_start && init_done && !init_error && !light_error) begin
                light_requested<=1;light_elapsed<=0;
            end else if(light_requested) begin
                if(light_elapsed>=CLK_HZ/1000*LIGHT_MAX_MS-1) begin
                    light_requested<=0;light_elapsed<=0;
                end else light_elapsed<=light_elapsed+1;
            end
            case(state)
                POWER: if(wait_count>=CLK_HZ/1000*POWER_DELAY_MS) begin
                    cam_pwdn<=0; wait_count<=0; state<=RELEASE_PWDN;
                end else wait_count<=wait_count+1;
                RELEASE_PWDN: if(wait_count>=CLK_HZ/1000*POWER_DELAY_MS) begin
                    cam_rst_n<=1; wait_count<=0; state<=RELEASE_RESET;
                end else wait_count<=wait_count+1;
                RELEASE_RESET: if(wait_count>=CLK_HZ/1000*RESET_DELAY_MS) begin
                    wait_count<=0; state<=ISSUE;
                end else wait_count<=wait_count+1;
                ISSUE: if(!bus_busy) begin
                    bus_start<=1; last_reg_addr<=command[23:8]; state<=WAIT_BUS;
                end
                WAIT_BUS: if(bus_done) begin
                    if(bus_ack_error) begin
                        ack_error_count<=ack_error_count+1;
                        if(retries<RETRY_LIMIT) begin
                            retries<=retries+1; wait_count<=0; wait_limit<=CLK_HZ/1000;
                            delay_next<=ISSUE; state<=DELAY;
                        end else begin init_error<=1; init_error_code<=8'h01; state<=FAILED; end
                    end else if(check_data && bus_read_data!=expected_data) begin
                        if(reg_index==0) chip_id[15:8]<=bus_read_data;
                        if(reg_index==1) chip_id[7:0]<=bus_read_data;
                        init_error<=1;
                        init_error_code<=(reg_index<2) ? 8'h02 : 8'h03;
                        state<=FAILED;
                    end else begin
                        retries<=0;
                        if(reg_index==0) chip_id[15:8]<=bus_read_data;
                        if(reg_index==1) chip_id[7:0]<=bus_read_data;
                        if(reg_index==END_INDEX) begin init_done<=1; state<=COMPLETE; end
                        else begin
                            reg_index<=reg_index+1;
                            if(reg_index==2 || reg_index==ROM_COUNT+1) begin
                                wait_count<=0;
                                wait_limit<=CLK_HZ/1000*((reg_index==2) ? SOFT_RESET_DELAY_MS : SETTLE_DELAY_MS);
                                delay_next<=ISSUE; state<=DELAY;
                            end else state<=ISSUE;
                        end
                    end
                end
                DELAY: if(wait_count>=wait_limit) begin wait_count<=0; state<=delay_next; end
                    else wait_count<=wait_count+1;
                COMPLETE: begin
                    init_done<=1;
                    if(light_requested!=light_on && !light_error) begin
                        light_target<=light_requested;retries<=0;state<=LIGHT_ISSUE;
                    end
                end
                LIGHT_ISSUE, LIGHT_READ: if(!bus_busy) begin
                    bus_start<=1;last_reg_addr<=16'h3019;
                    state<=(state==LIGHT_ISSUE)?LIGHT_WAIT:LIGHT_VERIFY;
                end
                LIGHT_WAIT, LIGHT_VERIFY: if(bus_done) begin
                    if(bus_ack_error) begin
                        ack_error_count<=ack_error_count+1;
                        if(retries<RETRY_LIMIT) begin
                            retries<=retries+1;wait_count<=0;wait_limit<=CLK_HZ/1000;
                            delay_next<=(state==LIGHT_WAIT)?LIGHT_ISSUE:LIGHT_READ;
                            state<=DELAY;
                        end else begin
                            light_error<=1;light_requested<=0;light_on<=0;
                            init_error<=1;init_done<=0;init_error_code<=8'h04;
                            // Reset the sensor if the off command cannot be
                            // acknowledged; do not leave an unknown LED state.
                            cam_rst_n<=0;state<=FAILED;
                        end
                    end else if(state==LIGHT_VERIFY && bus_read_data!=expected_data) begin
                        light_error<=1;light_requested<=0;light_on<=0;
                        init_error<=1;init_done<=0;init_error_code<=8'h04;
                        cam_rst_n<=0;state<=FAILED;
                    end else if(state==LIGHT_WAIT) begin retries<=0;state<=LIGHT_READ;end
                    else begin light_on<=light_target;retries<=0;state<=COMPLETE;end
                end
                FAILED: init_error<=1;
                default: state<=POWER;
            endcase
        end
    end
endmodule
