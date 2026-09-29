// Single codec-domain transaction to a 128-bit MIG native UI.
// Byte addresses are 16-byte aligned. MIG x16 / BL8 app_addr is measured in
// 16-bit words: byte_address >> 1, then +8 per 128-bit burst.
// All FIFO sides share rst_n. Neither ui_rst nor channel abort resets a FIFO.
// After calibration loss, UI reset or protocol failure, fatal is sticky and
// the active transaction terminates with done/error; recovery needs a common
// hard reset of bridge, codec and MIG. Cache-local abort must drain normally.
module ddr3_burst_bridge #(
    parameter FIFO_ADDR_BITS=6, MAX_READ_OUTSTANDING=16
)(
    input clk,rst_n,
    input cmd_valid,output cmd_ready,input cmd_write,
    input [27:0] cmd_addr,input [13:0] cmd_bytes,
    input [127:0] w_data,input [15:0] w_keep,input w_valid,
    output w_ready,input w_last,
    output [127:0] r_data,output r_valid,input r_ready,output r_last,
    output reg done,error,fatal,output ready,
    input ui_clk,ui_rst,init_calib_complete,
    output [27:0] app_addr,output [2:0] app_cmd,output app_en,input app_rdy,
    output [127:0] app_wdf_data,output [15:0] app_wdf_mask,
    output app_wdf_wren,input app_wdf_rdy,output app_wdf_end,
    input [127:0] app_rd_data,input app_rd_data_valid,app_rd_data_end
);
    localparam FIFO_DEPTH=1<<FIFO_ADDR_BITS;
    (* ASYNC_REG="TRUE" *) reg [2:0] codec_reset_pipe,ui_reset_pipe;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) codec_reset_pipe<=0;else codec_reset_pipe<={codec_reset_pipe[1:0],1'b1};
    always @(posedge ui_clk or negedge rst_n)
        if(!rst_n) ui_reset_pipe<=0;else ui_reset_pipe<={ui_reset_pipe[1:0],1'b1};
    wire codec_reset_n=codec_reset_pipe[2],ui_reset_n=ui_reset_pipe[2];
    reg busy,transaction_write;
    reg [9:0] write_ingested,transaction_words;
    reg request_toggle;
    // Bundled fields stay stable from request until terminal done. The request
    // toggle crosses two UI flops before these fields are sampled.
    reg request_write;
    reg [27:0] request_addr;
    reg [13:0] request_bytes;
    reg ui_completion_toggle,ui_fault,ui_seen_calibration;
    wire ui_available=ui_reset_n && init_calib_complete && !ui_rst && !ui_fault;
    (* ASYNC_REG="TRUE" *) reg calibrated_sync1,calibrated_sync2;
    (* ASYNC_REG="TRUE" *) reg ui_rst_sync1,ui_rst_sync2;
    (* ASYNC_REG="TRUE" *) reg ui_reset_release_sync1,ui_reset_release_sync2;
    (* ASYNC_REG="TRUE" *) reg completion_sync1,completion_sync2;
    (* ASYNC_REG="TRUE" *) reg fault_sync1,fault_sync2;
    reg completion_seen,read_consumed,ui_finished,codec_seen_calibration;
    reg [9:0] ui_words,ui_word_index,ui_read_returned;
    wire completion_event=completion_sync2!=completion_seen;
    wire [144:0] write_fifo_data;
    wire write_fifo_full,write_fifo_empty,write_fifo_pop;
    wire [128:0] read_fifo_data;
    wire read_fifo_full,read_fifo_empty,read_fifo_push;
    wire [FIFO_ADDR_BITS:0] read_fifo_used;
    // Synchronize each raw status independently. Combining asynchronous levels
    // before a synchronizer risks reconvergence glitches at the first stage.
    wire codec_available=calibrated_sync2 && !ui_rst_sync2 &&
                         ui_reset_release_sync2 && !fault_sync2;
    assign ready=codec_available && !fatal;
    assign cmd_ready=!busy && ready;
    assign w_ready=busy && transaction_write && !fatal && !write_fifo_full &&
                   write_ingested<transaction_words;
    assign r_valid=busy && !transaction_write && !fatal && !read_fifo_empty;
    assign r_data=read_fifo_data[127:0];
    assign r_last=read_fifo_data[128];
    wire read_last_consumed=r_valid && r_ready && r_last;
    ddr3_bridge_async_fifo #(.WIDTH(145),.ADDR_BITS(FIFO_ADDR_BITS)) write_fifo(
        .wr_rst_n(codec_reset_n),.rd_rst_n(ui_reset_n),.wr_clk(clk),.wr_en(w_valid && w_ready),
        .wr_data({w_last,w_keep,w_data}),.wr_full(write_fifo_full),.wr_used(),
        .rd_clk(ui_clk),.rd_en(write_fifo_pop),.rd_data(write_fifo_data),.rd_empty(write_fifo_empty));
    ddr3_bridge_async_fifo #(.WIDTH(129),.ADDR_BITS(FIFO_ADDR_BITS)) read_fifo(
        .wr_rst_n(ui_reset_n),.rd_rst_n(codec_reset_n),.wr_clk(ui_clk),.wr_en(read_fifo_push),
        .wr_data({ui_read_returned==ui_words-1'b1,app_rd_data}),
        .wr_full(read_fifo_full),.wr_used(read_fifo_used),
        .rd_clk(clk),.rd_en(r_valid && r_ready),.rd_data(read_fifo_data),.rd_empty(read_fifo_empty));
    always @(posedge clk or negedge codec_reset_n) begin
        if(!codec_reset_n) begin
            busy<=0;transaction_write<=0;write_ingested<=0;transaction_words<=0;
            request_toggle<=0;request_write<=0;request_addr<=0;request_bytes<=0;
            calibrated_sync1<=0;calibrated_sync2<=0;
            ui_rst_sync1<=1;ui_rst_sync2<=1;
            ui_reset_release_sync1<=0;ui_reset_release_sync2<=0;
            completion_sync1<=0;completion_sync2<=0;completion_seen<=0;
            fault_sync1<=0;fault_sync2<=0;
            read_consumed<=0;ui_finished<=0;codec_seen_calibration<=0;done<=0;error<=0;fatal<=0;
        end else begin
            calibrated_sync1<=init_calib_complete;calibrated_sync2<=calibrated_sync1;
            ui_rst_sync1<=ui_rst;ui_rst_sync2<=ui_rst_sync1;
            ui_reset_release_sync1<=ui_reset_n;ui_reset_release_sync2<=ui_reset_release_sync1;
            completion_sync1<=ui_completion_toggle;completion_sync2<=completion_sync1;
            fault_sync1<=ui_fault;fault_sync2<=fault_sync1;
            done<=0;error<=0;
            if(codec_available) codec_seen_calibration<=1;
            if(completion_event) completion_seen<=completion_sync2;
            // Raw MIG reset/calibration levels are sampled in the codec domain.
            // Their synchronized loss also terminates the transaction if the
            // UI clock has stopped and therefore cannot raise ui_fault itself.
            if((fault_sync2 || (codec_seen_calibration && !codec_available)) && !fatal) begin
                fatal<=1;done<=busy;error<=busy;busy<=0;
            end else if(!fatal) begin
                if(cmd_valid && cmd_ready) begin
                    if(cmd_addr[3:0]!=0 || cmd_bytes==0 || cmd_bytes>8192) begin
                        fatal<=1;done<=1;error<=1;
                    end else begin
                        request_write<=cmd_write;request_addr<=cmd_addr;request_bytes<=cmd_bytes;
                        request_toggle<=!request_toggle;busy<=1;transaction_write<=cmd_write;
                        transaction_words<=(cmd_bytes+14'd15)>>4;write_ingested<=0;
                        read_consumed<=0;ui_finished<=0;
                    end
                end
                if(w_valid && w_ready) write_ingested<=write_ingested+1'b1;
                if(busy && !transaction_write) begin
                    if(completion_event) ui_finished<=1;
                    if(read_last_consumed) read_consumed<=1;
                    if((ui_finished || completion_event) && (read_consumed || read_last_consumed)) begin
                        busy<=0;done<=1;
                    end
                end else if(busy && transaction_write && completion_event) begin
                    busy<=0;done<=1;
                end
            end
        end
    end
    (* ASYNC_REG="TRUE" *) reg request_sync1,request_sync2;
    (* ASYNC_REG="TRUE" *) reg local_fault_sync1,local_fault_sync2;
    reg request_seen,ui_active,ui_write;
    reg [27:0] ui_base;
    reg [10:0] ui_read_outstanding;
    reg write_command_accepted,write_data_accepted;
    wire ui_can_transfer=ui_active && ui_available && !local_fault_sync2;
    wire write_head_valid=ui_can_transfer && ui_write && !write_fifo_empty;
    wire read_capacity=(read_fifo_used+ui_read_outstanding<FIFO_DEPTH-2) &&
                       ui_read_outstanding<MAX_READ_OUTSTANDING;
    // Accept WDF before/concurrently with its command. UG586 allows data before
    // the command, but limits data arriving after an accepted command to two
    // clocks; independent random WDF stalls must never violate that limit.
    assign app_en=ui_can_transfer && (ui_write?
        (write_head_valid && !write_command_accepted && (write_data_accepted || app_wdf_rdy)):
        (ui_word_index<ui_words && read_capacity));
    assign app_cmd=ui_write?3'd0:3'd1;
    assign app_addr=ui_base+({18'd0,ui_word_index}<<3);
    assign app_wdf_data=write_fifo_data[127:0];
    assign app_wdf_mask=~write_fifo_data[143:128];
    assign app_wdf_wren=write_head_valid && !write_data_accepted;
    assign app_wdf_end=1'b1; // One 128-bit UI word is a complete x16 BL8 burst.
    wire command_accepted=app_en && app_rdy;
    wire data_accepted=app_wdf_wren && app_wdf_rdy;
    assign write_fifo_pop=write_head_valid &&
        (write_command_accepted || command_accepted) && (write_data_accepted || data_accepted);
    wire read_response_expected=ui_can_transfer && !ui_write &&
        (ui_read_outstanding!=0 || command_accepted) && ui_read_returned<ui_words;
    assign read_fifo_push=app_rd_data_valid && read_response_expected &&
                          app_rd_data_end && !read_fifo_full;
    always @(posedge ui_clk or negedge ui_reset_n) begin
        if(!ui_reset_n) begin
            request_sync1<=0;request_sync2<=0;request_seen<=0;
            local_fault_sync1<=0;local_fault_sync2<=0;
            ui_completion_toggle<=0;ui_fault<=0;ui_seen_calibration<=0;
            ui_active<=0;ui_write<=0;ui_base<=0;ui_words<=0;
            ui_word_index<=0;ui_read_returned<=0;ui_read_outstanding<=0;
            write_command_accepted<=0;write_data_accepted<=0;
        end else begin
            request_sync1<=request_toggle;request_sync2<=request_sync1;
            local_fault_sync1<=fatal;local_fault_sync2<=local_fault_sync1;
            if(init_calib_complete && !ui_rst) ui_seen_calibration<=1;
            if(local_fault_sync2 || (ui_seen_calibration && (ui_rst || !init_calib_complete))) begin
                ui_fault<=1;ui_active<=0;
            end else if(!ui_fault && !ui_rst) begin
                if(request_sync2!=request_seen && !ui_active && init_calib_complete) begin
                    request_seen<=request_sync2;ui_active<=1;ui_write<=request_write;
                    ui_base<={1'b0,request_addr[27:1]};ui_words<=(request_bytes+14'd15)>>4;
                    ui_word_index<=0;ui_read_returned<=0;ui_read_outstanding<=0;
                    write_command_accepted<=0;write_data_accepted<=0;
                end else if(ui_can_transfer) begin
                    if(ui_write) begin
                        if(app_rd_data_valid) begin ui_fault<=1;ui_active<=0;end
                        if(command_accepted) write_command_accepted<=1;
                        if(data_accepted) write_data_accepted<=1;
                        if(write_fifo_pop) begin
                            write_command_accepted<=0;write_data_accepted<=0;
                            if(write_fifo_data[144]!=(ui_word_index==ui_words-1'b1)) begin
                                ui_fault<=1;ui_active<=0;
                            end else if(ui_word_index==ui_words-1'b1) begin
                                ui_active<=0;ui_completion_toggle<=!ui_completion_toggle;
                            end
                            ui_word_index<=ui_word_index+1'b1;
                        end
                    end else begin
                        if(command_accepted) ui_word_index<=ui_word_index+1'b1;
                        case({command_accepted,read_fifo_push})
                            2'b10:ui_read_outstanding<=ui_read_outstanding+1'b1;
                            2'b01:ui_read_outstanding<=ui_read_outstanding-1'b1;
                        endcase
                        if(app_rd_data_valid) begin
                            if(!read_response_expected || !app_rd_data_end || read_fifo_full) begin
                                ui_fault<=1;ui_active<=0;
                            end else begin
                                ui_read_returned<=ui_read_returned+1'b1;
                                if(ui_read_returned==ui_words-1'b1) begin
                                    ui_active<=0;ui_completion_toggle<=!ui_completion_toggle;
                                end
                            end
                        end
                    end
                end else if(app_rd_data_valid && !ui_rst) begin
                    ui_fault<=1;ui_active<=0; // Unsolicited/out-of-order response.
                end
            end
        end
    end
endmodule

// Gray-pointer asynchronous FIFO with LUTRAM asynchronous first-word fallthrough.
// Data is committed before its Gray write pointer crosses two synchronizers.
// Pointer buses need the usual source-clock max-delay/bus-skew constraints.
// ADDR_BITS >= 2. Both reset inputs come ONLY from the same common global
// assertion and domain-synchronized release above. No per-domain live clear.
module ddr3_bridge_async_fifo #(parameter WIDTH=129,ADDR_BITS=6)(
    input wr_rst_n,rd_rst_n,input wr_clk,wr_en,input [WIDTH-1:0] wr_data,
    output wr_full,output [ADDR_BITS:0] wr_used,
    input rd_clk,rd_en,output [WIDTH-1:0] rd_data,output rd_empty
);
    (* ram_style="distributed" *) reg [WIDTH-1:0] memory[0:(1<<ADDR_BITS)-1];
    reg [ADDR_BITS:0] wr_binary,wr_gray,rd_binary,rd_gray;
    (* ASYNC_REG="TRUE" *) reg [ADDR_BITS:0] rd_gray_sync1,rd_gray_sync2;
    (* ASYNC_REG="TRUE" *) reg [ADDR_BITS:0] wr_gray_sync1,wr_gray_sync2;
    function [ADDR_BITS:0] gray_to_binary;
        input [ADDR_BITS:0] value;
        integer index;
        begin
            gray_to_binary[ADDR_BITS]=value[ADDR_BITS];
            for(index=ADDR_BITS-1;index>=0;index=index-1)
                gray_to_binary[index]=gray_to_binary[index+1]^value[index];
        end
    endfunction
    assign wr_full=wr_gray=={~rd_gray_sync2[ADDR_BITS:ADDR_BITS-1],rd_gray_sync2[ADDR_BITS-2:0]};
    assign rd_empty=rd_gray==wr_gray_sync2;
    assign wr_used=wr_binary-gray_to_binary(rd_gray_sync2);
    assign rd_data=memory[rd_binary[ADDR_BITS-1:0]];
    wire [ADDR_BITS:0] wr_next=wr_binary+1'b1,rd_next=rd_binary+1'b1;
    // Keep the RAM itself out of the asynchronous pointer-reset process.
    // Entries are not reset; empty pointers hide stale data after common reset.
    always @(posedge wr_clk)
        if(wr_rst_n && wr_en && !wr_full) memory[wr_binary[ADDR_BITS-1:0]]<=wr_data;
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if(!wr_rst_n) begin wr_binary<=0;wr_gray<=0;rd_gray_sync1<=0;rd_gray_sync2<=0;end
        else begin
            rd_gray_sync1<=rd_gray;rd_gray_sync2<=rd_gray_sync1;
            if(wr_en && !wr_full) begin
                wr_binary<=wr_next;wr_gray<=(wr_next>>1)^wr_next;
            end
        end
    end
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if(!rd_rst_n) begin rd_binary<=0;rd_gray<=0;wr_gray_sync1<=0;wr_gray_sync2<=0;end
        else begin
            wr_gray_sync1<=wr_gray;wr_gray_sync2<=wr_gray_sync1;
            if(rd_en && !rd_empty) begin rd_binary<=rd_next;rd_gray<=(rd_next>>1)^rd_next;end
        end
    end
endmodule
