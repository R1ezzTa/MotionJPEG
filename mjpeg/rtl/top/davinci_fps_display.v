// Six common-anode digits: active-low digit/segment outputs. Vendor mapping:
// seg_sel[0] is units; seg_led[0:6] are a,b,c,d,e,f,g; bit7 is decimal point.
module davinci_fps_display #(parameter CLOCK_HZ=50000000)(
    input clk,rst_n,input [31:0] fps,input update_valid,
    output reg [5:0] seg_sel,output reg [7:0] seg_led,
    output reg [23:0] bcd_value
);
    localparam SCAN_CYCLES=CLOCK_HZ/1000;
    localparam BLANK_CYCLES=(CLOCK_HZ/500000<1)?1:CLOCK_HZ/500000;
    reg [43:0] work,adjusted,next_work;
    reg [4:0] conversion_index;
    reg converting;
    integer d;
    always @* begin
        adjusted=work;
        for(d=0;d<6;d=d+1)
            if(work[20+d*4+:4]>=5) adjusted[20+d*4+:4]=work[20+d*4+:4]+4'd3;
        next_work=adjusted<<1;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin work<=0;conversion_index<=0;converting<=0;bcd_value<=0; end
        else if(update_valid) begin
            work<={24'd0,((fps>999999)?20'd999999:fps[19:0])};
            conversion_index<=0;converting<=1;
        end else if(converting) begin
            work<=next_work;
            if(conversion_index==19) begin bcd_value<=next_work[43:20];converting<=0; end
            else conversion_index<=conversion_index+1'b1;
        end
    end
    function [7:0] digit_code;
        input [3:0] digit;
        begin
            case(digit)
                0:digit_code=8'hc0;1:digit_code=8'hf9;2:digit_code=8'ha4;3:digit_code=8'hb0;
                4:digit_code=8'h99;5:digit_code=8'h92;6:digit_code=8'h82;7:digit_code=8'hf8;
                8:digit_code=8'h80;9:digit_code=8'h90;default:digit_code=8'hff;
            endcase
        end
    endfunction
    reg [31:0] scan_count;
    reg [2:0] digit_index;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin scan_count<=0;digit_index<=0;seg_sel<=6'b111111;seg_led<=8'hff; end
        else begin
            if(scan_count==0) begin seg_sel<=6'b111111;seg_led<=8'hff; end
            if(scan_count==BLANK_CYCLES) seg_led<=digit_code(bcd_value[digit_index*4+:4]);
            if(scan_count==2*BLANK_CYCLES) seg_sel<=~(6'b000001<<digit_index);
            if(scan_count==SCAN_CYCLES-1) begin
                scan_count<=0;digit_index<=(digit_index==5)?0:digit_index+1'b1;
            end else scan_count<=scan_count+1'b1;
        end
    end
endmodule
