`timescale 1ns/1ps
// Behavioral SCCB sensor: validates electrical transactions, chip ID, register
// programming/readback, power sequencing, NACK retries and bad-ID handling.
module tb_ov5640_init #(parameter CAMERA_PROFILE=0);
    localparam FINAL_INDEX=(CAMERA_PROFILE>=4)?283:(CAMERA_PROFILE>=1)?277:270;
    localparam W=(CAMERA_PROFILE>=4)?1920:(CAMERA_PROFILE>=2)?1280:640;
    localparam H=(CAMERA_PROFILE>=4)?1080:(CAMERA_PROFILE>=2)?720:480;
    localparam VTS=(CAMERA_PROFILE>=4)?1116:(CAMERA_PROFILE>=2)?740:1000;
    localparam HTS=(CAMERA_PROFILE>=4)?2240:(CAMERA_PROFILE==3)?1690:(CAMERA_PROFILE==2)?1896:1600;
    reg clk=0; always #500 clk=~clk;
    reg rst_n=0;
    reg light_start=0,light_cancel=0;
    wire light_requested,light_on,light_error,light_busy;
    wire scl, cam_rst_n,cam_pwdn,init_done,init_error;
    tri1 sda;
    wire sda_drive_low;
    assign sda=sda_drive_low ? 1'b0 : 1'bz;
    wire [15:0] chip_id,ack_errors,last_reg;
    wire [8:0] index;
    wire [7:0] error_code;
    ov5640_init #(.CLK_HZ(1000000),.SCCB_HZ(25000),.CAMERA_PROFILE(CAMERA_PROFILE),
        .POWER_DELAY_MS(1),.RESET_DELAY_MS(1),
        .SOFT_RESET_DELAY_MS(1),.SETTLE_DELAY_MS(1),.LIGHT_MAX_MS(20)) dut(
        .clk(clk),.rst_n(rst_n),.cam_rst_n(cam_rst_n),.cam_pwdn(cam_pwdn),
        .light_start(light_start),.light_cancel(light_cancel),
        .light_requested(light_requested),.light_on(light_on),.light_error(light_error),.light_busy(light_busy),
        .cam_scl(scl),.cam_sda_i(sda),.cam_sda_drive_low(sda_drive_low),
        .init_done(init_done),.init_error(init_error),
        .init_error_code(error_code),.chip_id(chip_id),.reg_index(index),
        .ack_error_count(ack_errors),.last_reg_addr(last_reg));
    reg slave_low=0;
    assign sda=slave_low ? 1'b0 : 1'bz;
    reg [7:0] mem [0:65535];
    reg [7:0] byte_rx=0,byte_tx=0;
    reg [15:0] addr=0;
    integer bits=0,stage=0,writes=0;
    integer nack_budget=0;
    reg transfer=0,reading=0,ack_pending=0;
    reg bad_id=0;
    reg bad_readback=0;
    reg bad_light_readback=0;
    always @(negedge sda) if(scl && !slave_low && rst_n) begin
        transfer=1; bits=0; stage=0; reading=0; byte_rx=0; ack_pending=0;
    end
    always @(posedge sda) if(scl && !slave_low && rst_n) transfer=0;
    always @(posedge scl) if(transfer && rst_n) begin
        if(reading && stage==1) begin
            if(bits<8) bits=bits+1;
            else begin bits=0; stage=2; end // master's final NACK
        end else if(bits<8) begin
            byte_rx={byte_rx[6:0],sda}; bits=bits+1;
            if(bits==8) begin
                case(stage)
                    0: begin
                        if(byte_rx!=8'h78 && byte_rx!=8'h79) $fatal(1,"wrong slave address %02x",byte_rx);
                        reading=byte_rx[0];
                        if(reading) begin
                            byte_tx=mem[addr];
                            if(bad_id && addr==16'h300a) byte_tx=8'h99;
                            if(bad_readback && addr==16'h4740) byte_tx=8'h21;
                            if(bad_light_readback && addr==16'h3019) byte_tx=mem[addr]^8'h02;
                        end
                    end
                    1: addr[15:8]=byte_rx;
                    2: addr[7:0]=byte_rx;
                    3: begin mem[addr]=byte_rx; writes=writes+1; end
                endcase
                ack_pending=1;
            end
        end else begin bits=0; stage=stage+1; ack_pending=0; end
    end
    always @(negedge scl) if(transfer && rst_n) begin
        if(reading && stage==1) begin
            if(bits<8) slave_low=~byte_tx[7-bits]; else slave_low=0;
        end else if(ack_pending) begin
            if(nack_budget>0 && stage==0) begin slave_low=0; nack_budget=nack_budget-1; end
            else slave_low=1;
        end else slave_low=0;
    end else slave_low=0;
    task reset_sensor;
        integer k;
        begin
            rst_n=0; transfer=0; slave_low=0;light_start=0;light_cancel=0;
            for(k=0;k<65536;k=k+1) mem[k]=0;
            mem[16'h300a]=8'h56; mem[16'h300b]=8'h40;
            repeat(10) @(posedge clk); rst_n=1;
        end
    endtask
    task light_command(input bit turn_on);
        begin
            @(negedge clk);light_start=turn_on;light_cancel=!turn_on;
            @(negedge clk);light_start=0;light_cancel=0;
        end
    endtask
    initial begin
        reset_sensor();
        #500000;
        if(cam_rst_n || !cam_pwdn) $fatal(1,"powerdown/reset hold missing");
        nack_budget=1;
        wait(init_done || init_error);
        if(init_error || chip_id!=16'h5640 || ack_errors!=1) $fatal(1,"init failed: idx=%0d err=%0d id=%04x ack=%0d",index,error_code,chip_id,ack_errors);
        if(mem[16'h4300]!=((CAMERA_PROFILE==5)?0:8'h30) || mem[16'h501f]!=((CAMERA_PROFILE==5)?3:0) ||
           {mem[16'h3808],mem[16'h3809]}!=W || {mem[16'h380a],mem[16'h380b]}!=H)
            $fatal(1,"wrong pixel format/dimensions profile %0d",CAMERA_PROFILE);
        if(mem[16'h4740]!=8'h20) $fatal(1,"wrong DVP polarity");
        if({mem[16'h380e],mem[16'h380f]}!=VTS || {mem[16'h380c],mem[16'h380d]}!=HTS)
            $fatal(1,"wrong frame period for profile %0d",CAMERA_PROFILE);
        if(CAMERA_PROFILE>=2 && (mem[16'h3037]!=8'h14 || mem[16'h3036]!=((CAMERA_PROFILE>=3)?8'h64:8'h70) || mem[16'h3034]!=8'h18))
            $fatal(1,"wrong HD PLL setup");
        if(CAMERA_PROFILE>=2 && mem[16'h3820]!=((CAMERA_PROFILE==5)?8'h42:(CAMERA_PROFILE>=4)?8'h46:8'h47))
            $fatal(1,"HD orientation differs from validated VGA orientation");
        if(CAMERA_PROFILE>=2 && mem[16'h3821]!=((CAMERA_PROFILE>=4)?0:1))
            $fatal(1,"horizontal binning does not match crop mode");
        if(CAMERA_PROFILE>=4 && (mem[16'h4514]!=0 || mem[16'h4520]!=8'h10))
            $fatal(1,"unbinned vflip sampling options missing");
        if(writes!=((CAMERA_PROFILE>=4)?262:260)) $fatal(1,"incomplete setup (%0d)",writes);
        $display("PASS init VGA YUYV: chip=%04x writes=%0d recovered NACK=%0d",chip_id,writes,ack_errors);
        if(index!=FINAL_INDEX) $fatal(1,"last register index unexpected");
        if(mem[16'h3016]!=2 || mem[16'h301c]!=2 || mem[16'h3019]!=0)
            $fatal(1,"STROBE GPIO setup/default off missing");
        light_command(1);wait(light_on && !light_busy);
        if(!light_requested || mem[16'h3019]!=2 || light_error || !init_done || index!=FINAL_INDEX)
            $fatal(1,"runtime light on/readback failed");
        light_command(0);wait(!light_on && !light_busy);
        if(mem[16'h3019]!=0 || light_requested) $fatal(1,"explicit light off failed");
        $display("PASS light on/off verified by SCCB readback");
        light_command(1);wait(light_on);wait(!light_requested);wait(!light_on && !light_busy);
        if(mem[16'h3019]!=0 || light_error) $fatal(1,"automatic light timeout failed");
        $display("PASS light hardware timeout without host command");
        light_command(1);wait(dut.state==9);light_command(0);
        // Sample after all NBA updates: state and verified output may change
        // together when the in-flight ON readback completes.
        @(negedge clk);
        while(dut.state!=6 || light_on || light_requested) @(negedge clk);
        if(mem[16'h3019]!=0) $fatal(1,"cancel during SCCB write failed: state=%0d on=%b target=%b value=%02x",dut.state,light_on,dut.light_target,mem[16'h3019]);
        $display("PASS cancellation while light command in flight");
        light_command(1);wait(light_on && !light_busy);
        nack_budget=10;light_command(0);wait(init_error);
        if(!light_error || error_code!=4 || cam_rst_n || init_done || light_requested)
            $fatal(1,"failed off must reset sensor");
        $display("PASS failed light off resets sensor after bounded retries");
        nack_budget=0;
        bad_readback=1; reset_sensor();
        wait(init_error);
        if(error_code!=3 || last_reg!=16'h4740 || init_done) $fatal(1,"bad readback not detected");
        $display("PASS DVP polarity readback diagnosis");
        bad_readback=0;
        bad_id=1; reset_sensor();
        wait(init_error);
        if(error_code!=2 || chip_id[15:8]!=8'h99 || init_done) $fatal(1,"bad chip ID did not stop init");
        $display("PASS bad chip ID diagnosis");
        bad_id=0; reset_sensor(); nack_budget=10;
        wait(init_error);
        if(error_code!=1 || ack_errors!=3 || init_done) $fatal(1,"persistent NACK not detected");
        $display("PASS persistent NACK diagnosis and retry limit");
        nack_budget=0;reset_sensor();wait(init_done);
        bad_light_readback=1;light_command(1);wait(init_error);
        if(!light_error || error_code!=4 || cam_rst_n || init_done)
            $fatal(1,"bad light readback must reset sensor");
        $display("PASS light register readback mismatch diagnosis");
        $finish;
    end
    initial begin #(64'd3000000000); $fatal(1,"simulation timeout: idx=%0d state=%0d",index,dut.state); end
endmodule
