`timescale 1ns/1ps
module tb_fps_peripherals;
    reg clk=0,rst_n=0,in_frame=0,ok_frame=0,bad_frame=0;
    always #10 clk=~clk;
    wire valid;
    wire [31:0] window_id,in_fps,ok_fps,bad_fps,total;
    frame_rate_meter #(.CLOCK_HZ(32)) meter(.clk(clk),.rst_n(rst_n),.input_frame(in_frame),
        .success_frame(ok_frame),.failed_frame(bad_frame),.sample_valid(valid),.window_id(window_id),
        .input_fps(in_fps),.compressed_fps(ok_fps),.failed_fps(bad_fps),.total_compressed(total));
    reg [31:0] display_number=0;
    reg display_update=0;
    wire [5:0] sel;
    wire [7:0] segments;
    wire [23:0] bcd;
    davinci_fps_display #(.CLOCK_HZ(1000000)) display(.clk(clk),.rst_n(rst_n),.fps(display_number),
        .update_valid(display_update),.seg_sel(sel),.seg_led(segments),.bcd_value(bcd));
    integer cycle=0,reference_in=0,reference_ok=0,reference_bad=0,reference_total=0,samples=0;
    integer i,j,marker;
    reg [7:0] expected_codes[0:9];
    reg [5:0] seen;
    reg previous_valid=0;
    // Independent reference windows, including events on the boundary clock.
    always @(posedge clk) if(rst_n) begin
        cycle=cycle+1;reference_in=reference_in+in_frame;reference_ok=reference_ok+ok_frame;
        reference_bad=reference_bad+bad_frame;reference_total=reference_total+ok_frame;
        #1;
        if(valid) begin
            if(cycle%32!=0 || previous_valid) $fatal(1,"Window pulse timing");
            samples=samples+1;
            if(window_id!=samples || in_fps!=reference_in || ok_fps!=reference_ok ||
               bad_fps!=reference_bad || total!=reference_total) $fatal(1,"FPS boundary/idle/count mismatch");
            reference_in=0;reference_ok=0;reference_bad=0;
        end
        previous_valid=valid;
    end
    task show_and_check(input [31:0] number,input [23:0] expected);
        begin
            @(negedge clk);display_number=number;display_update=1;
            @(negedge clk);display_update=0;
            repeat(25) @(negedge clk);
            if(bcd!==expected) $fatal(1,"Decimal conversion number=%0d got=%h",number,bcd);
            // A selected digit holds its previous segment code until its next
            // refresh; allow one complete scan after the BCD update.
            repeat(6000) @(negedge clk);
            seen=0;
            repeat(7000) begin
                @(negedge clk);
                if(sel!=6'b111111) begin
                    if(!$onehot(~sel)) $fatal(1,"Digit selection collision");
                    for(j=0;j<6;j=j+1) if(!sel[j]) begin
                        seen[j]=1;
                        if(segments!==expected_codes[expected[j*4+:4]]) $fatal(1,"Digit order/segment polarity");
                    end
                end
            end
            if(seen!==6'b111111) $fatal(1,"Missing digit refresh");
        end
    endtask
    initial begin
        expected_codes[0]=8'hc0;expected_codes[1]=8'hf9;expected_codes[2]=8'ha4;expected_codes[3]=8'hb0;
        expected_codes[4]=8'h99;expected_codes[5]=8'h92;expected_codes[6]=8'h82;expected_codes[7]=8'hf8;
        expected_codes[8]=8'h80;expected_codes[9]=8'h90;
        repeat(5) @(negedge clk);rst_n=1;
        for(i=1;i<=96;i=i+1) begin
            in_frame=(i<=32 && (i==1 || i==16 || i==32));
            ok_frame=(i<=32 && (i==16 || i==32));bad_frame=(i==24);
            @(negedge clk);
        end
        in_frame=0;ok_frame=0;bad_frame=0;
        if(samples<3 || in_fps!=0 || ok_fps!=0 || bad_fps!=0 || total!=2) $fatal(1,"Idle rate should be zero");
        show_and_check(0,24'h000000);show_and_check(338,24'h000338);
        show_and_check(123456,24'h123456);show_and_check(999999,24'h999999);
        show_and_check(1000000,24'h999999);show_and_check(0,24'h000000);
        @(negedge clk);rst_n=0;@(negedge clk);
        if(bcd!=0 || sel!=6'b111111 || total!=0 || window_id!=0) $fatal(1,"Reset outputs");
        marker=$fopen("PERIPHERALS_PASS.txt","w");
        $fdisplay(marker,"FPS boundary/failed/idle/reset counts and BCD polarity/order/scanning/saturation passed");
        $fclose(marker);$finish;
    end
endmodule
