// Active-low DaVinci keys. Each press generates one event after 20 ms of
// stable input; holding a key cannot restart the finite OV5640 light timer.
module camera_board_controls #(
    parameter CLOCK_HZ=100000000, DEBOUNCE_CYCLES=CLOCK_HZ/50,
    COMMAND_TIMEOUT_CYCLES=(CLOCK_HZ<10)?1:CLOCK_HZ/10,
    SPATIAL_COMMANDS=1,DENOISE_COMMANDS=0,PREPROCESS_COMMANDS=0
)(
    input clk,reset_n,input [3:0] key_n,
    input [7:0] rx_data,input rx_valid,
    input streaming,camera_ready,input [1:0] active_quality,
    input light_on,fault,
    output reg run_requested,output reg [1:0] quality_requested,
    output reg [7:0] spatial_threshold_requested,
    output reg spatial_adaptive_requested,
    output reg [7:0] denoise_strength_requested,
    output reg [1:0] preprocess_mode_requested,
    output reg [7:0] binary_threshold_requested,edge_threshold_requested,
    output reg light_start,light_cancel,output [3:0] led
);
    (* ASYNC_REG="TRUE" *) reg [2:0] reset_pipe=0;
    always @(posedge clk or negedge reset_n)
        if(!reset_n) reset_pipe<=0;else reset_pipe<={reset_pipe[1:0],1'b1};
    wire rst_n=reset_pipe[2];
    (* ASYNC_REG="TRUE" *) reg [3:0] key_meta,key_sync;
    reg [3:0] stable,pressed;
    localparam COUNT_BITS=(DEBOUNCE_CYCLES<2)?1:$clog2(DEBOUNCE_CYCLES);
    reg [COUNT_BITS-1:0] count[0:3];
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            key_meta<=4'hf;key_sync<=4'hf;stable<=4'hf;pressed<=0;
            for(i=0;i<4;i=i+1) count[i]<=0;
        end else begin
            key_meta<=key_n;key_sync<=key_meta;pressed<=0;
            for(i=0;i<4;i=i+1) begin
                if(key_sync[i]==stable[i]) count[i]<=0;
                else if(count[i]==DEBOUNCE_CYCLES-1) begin
                    count[i]<=0;stable[i]<=key_sync[i];pressed[i]<=!key_sync[i];
                end else count[i]<=count[i]+1'b1;
            end
        end
    end
    // Txx\n updates the threshold atomically. Payload bytes are never legacy
    // commands (notably hex C/F and malformed S/L). Malformed input is drained
    // to newline, or abandoned after 100 ms without another byte.
    localparam CMD_IDLE=0,CMD_HIGH=1,CMD_LOW=2,CMD_END=3,CMD_DRAIN=4,CMD_AUTO=5,CMD_AUTO_END=6;
    localparam TIMEOUT_BITS=(COMMAND_TIMEOUT_CYCLES<2)?1:$clog2(COMMAND_TIMEOUT_CYCLES);
    reg [2:0] command_state;
    reg [TIMEOUT_BITS-1:0] command_idle_count;
    reg [7:0] pending_threshold;
    reg [2:0] command_kind; // T, N, B, M, E
    reg pending_adaptive;
    function hex_valid;
        input [7:0] value;
        begin hex_valid=(value>="0" && value<="9") ||
                        (value>="A" && value<="F") || (value>="a" && value<="f");end
    endfunction
    function [3:0] hex_value;
        input [7:0] value;
        begin
            if(value>="0" && value<="9") hex_value=value-"0";
            else if(value>="A" && value<="F") hex_value=value-"A"+10;
            else hex_value=value-"a"+10;
        end
    endfunction
    wire legacy_command=rx_valid && command_state==CMD_IDLE && rx_data!="T" && rx_data!="A" && rx_data!="N" && rx_data!="B" && rx_data!="M" && rx_data!="E";
    // USB commands remain useful for automated acceptance. Board keys and
    // host commands update the same FPGA state; PC software owns no timer.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            run_requested<=0;quality_requested<=2;light_start<=0;light_cancel<=0;
            spatial_threshold_requested<=0;pending_threshold<=0;
            spatial_adaptive_requested<=0;pending_adaptive<=0;
            denoise_strength_requested<=0;command_kind<=0;
            preprocess_mode_requested<=0;binary_threshold_requested<=128;edge_threshold_requested<=32;
            command_state<=CMD_IDLE;command_idle_count<=0;
        end else begin
            light_start<=0;light_cancel<=0;
            if(rx_valid) begin
                command_idle_count<=0;
                case(command_state)
                    CMD_IDLE: begin
                        if(rx_data=="T" || rx_data=="N" || rx_data=="B" || rx_data=="M" || rx_data=="E") begin
                            case(rx_data)
                                "T":command_kind<=0;"N":command_kind<=1;"B":command_kind<=2;
                                "M":command_kind<=3;"E":command_kind<=4;
                            endcase
                            command_state<=CMD_HIGH;
                        end
                        else if(rx_data=="A") command_state<=CMD_AUTO;
                    end
                    CMD_AUTO: begin
                        if(rx_data=="0" || rx_data=="1") begin
                            pending_adaptive<=rx_data=="1";command_state<=CMD_AUTO_END;
                        end else command_state<=(rx_data==8'h0a)?CMD_IDLE:CMD_DRAIN;
                    end
                    CMD_AUTO_END: begin
                        if(rx_data==8'h0a) begin
                            if(SPATIAL_COMMANDS) spatial_adaptive_requested<=pending_adaptive;
                            command_state<=CMD_IDLE;
                        end else command_state<=CMD_DRAIN;
                    end
                    CMD_HIGH: begin
                        if(hex_valid(rx_data)) begin
                            pending_threshold[7:4]<=hex_value(rx_data);command_state<=CMD_LOW;
                        end else command_state<=(rx_data==8'h0a)?CMD_IDLE:CMD_DRAIN;
                    end
                    CMD_LOW: begin
                        if(hex_valid(rx_data)) begin
                            pending_threshold[3:0]<=hex_value(rx_data);command_state<=CMD_END;
                        end else command_state<=(rx_data==8'h0a)?CMD_IDLE:CMD_DRAIN;
                    end
                    CMD_END: begin
                        if(rx_data==8'h0a) begin
                            case(command_kind)
                                0:if(SPATIAL_COMMANDS) spatial_threshold_requested<=pending_threshold;
                                1:if(DENOISE_COMMANDS) denoise_strength_requested<=pending_threshold;
                                2:if(PREPROCESS_COMMANDS) binary_threshold_requested<=pending_threshold;
                                3:if(PREPROCESS_COMMANDS && pending_threshold<4) preprocess_mode_requested<=pending_threshold[1:0];
                                4:if(PREPROCESS_COMMANDS) edge_threshold_requested<=pending_threshold;
                            endcase
                            command_state<=CMD_IDLE;
                        end else command_state<=CMD_DRAIN;
                    end
                    CMD_DRAIN: if(rx_data==8'h0a) command_state<=CMD_IDLE;
                    default: command_state<=CMD_IDLE;
                endcase
            end else if(command_state!=CMD_IDLE) begin
                if(command_idle_count==COMMAND_TIMEOUT_CYCLES-1) begin
                    command_state<=CMD_IDLE;command_idle_count<=0;
                end else command_idle_count<=command_idle_count+1'b1;
            end
            if(pressed[0]) begin
                run_requested<=!run_requested;
                if(run_requested) light_cancel<=1;
            end
            if(legacy_command && (rx_data=="C" || rx_data=="G" || rx_data=="V" || rx_data=="H" || rx_data=="F"))
                run_requested<=1;
            if(pressed[1] || (legacy_command && rx_data=="Q"))
                quality_requested<=(quality_requested==2)?0:quality_requested+1'b1;
            if(legacy_command && rx_data>="1" && rx_data<="3") quality_requested<=rx_data-"1";
            if(camera_ready && (pressed[2] || (legacy_command && rx_data=="L"))) light_start<=1;
            if(legacy_command && rx_data=="l") begin light_cancel<=1;light_start<=0;end
            // STOP wins over simultaneous START, quality or light presses.
            if(pressed[3] || (legacy_command && rx_data=="S") || (pressed[0] && run_requested)) begin
                run_requested<=0;light_cancel<=1;light_start<=0;
            end
        end
    end
    localparam BLINK_HALF=(CLOCK_HZ<10)?1:CLOCK_HZ/10;
    localparam BLINK_BITS=(BLINK_HALF<2)?1:$clog2(BLINK_HALF);
    reg [BLINK_BITS-1:0] blink_count;
    reg blink_fast;
    reg [2:0] blink_div;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin blink_count<=0;blink_fast<=0;blink_div<=0;end
        else if(blink_count==BLINK_HALF-1) begin
            blink_count<=0;blink_fast<=!blink_fast;blink_div<=blink_div+1'b1;
        end else blink_count<=blink_count+1'b1;
    end
    // LED1 is the low bit, LED2 the high bit: 00 Q60, 01 Q75, 10 Q85.
    // While stopped, indicate the selection to use on the next start.
    wire [1:0] shown_quality=streaming?active_quality:quality_requested;
    assign led={fault?blink_fast:light_on,shown_quality,
                (run_requested && !camera_ready)?blink_div[2]:streaming};
endmodule
