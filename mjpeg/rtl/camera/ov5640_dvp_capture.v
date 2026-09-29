// OV5640 8-bit DVP YUV422 capture -> low-Y/high-Cb-or-Cr pixels.
// VSYNC/HREF active high. SAMPLE_FALLING selects the sampling clock edge;
// the physical top supplies an aligned register stage on that same edge.
// RAW8 stores one byte/pixel (no YUV byte pairing), preserving all markers.
// YUV_BYTE_ORDER=1: U,Y0,V,Y1; 0: Y0,U,Y1,V. Even pixels carry Cb.
// enable is an admission request from core_clk. ADMIT_AT_HREF delays its
// one-shot sampling from VSYNC falling until the first active HREF byte.
// It may drop when the codec becomes busy without interrupting an admitted frame.
// A broken line or FIFO overflow flushes both FIFO pointers and emits s_abort.
// No later frame enters the queue until the flush/abort handshake completes.
module ov5640_dvp_capture #(
    parameter WIDTH=640,HEIGHT=480,FIFO_ADDRESS_BITS=12,YUV_BYTE_ORDER=1,RAW8=0,SAMPLE_FALLING=0,ADMIT_AT_HREF=0
)(
    input pclk,input rst_n,input enable,
    input cam_vsync,input cam_href,input [7:0] cam_data,
    input core_clk,input core_rst_n,
    output [15:0] s_data,output s_valid,input s_ready,
    output s_sof,output s_eol,output s_eof,output reg s_abort,
    output capture_active,output admission_enabled,output queue_pressure,
    output [31:0] received_frames,output [31:0] dropped_frames,
    output [31:0] overflow_count,output [31:0] frame_sync_count,
    output [31:0] dvp_byte_count,output [31:0] captured_pixels,
    output [31:0] pclk_ticks
);
    wire sample_clk=SAMPLE_FALLING?~pclk:pclk;
    wire reset_n=rst_n && core_rst_n;
    // Share the FIFO's sole common-reset entrance into the PCLK domain.
    // This reset is global-only: a fault flush must not clear its own request.
    wire pclk_reset_n,rflush_active;
    (* ASYNC_REG="TRUE" *) reg [1:0] enable_sync,ack_sync;
    reg vsync_d,href_d,in_frame,byte_phase,admission_pending;
    reg [7:0] first_byte;
    reg [15:0] x,y;
    reg fault_req;
    reg fault_ack;
    wire vsync_rise=cam_vsync && !vsync_d;
    wire vsync_fall=!cam_vsync && vsync_d;
    wire href_fall=!cam_href && href_d;
    wire fifo_ready;
    wire first_href=ADMIT_AT_HREF && admission_pending && !cam_vsync && cam_href;
    wire admit_first=first_href && enable_sync[1] && !ack_sync[1] && !fault_req;
    // RAW8 must enqueue byte zero on the admission edge itself. In YUV mode
    // that same edge latches the first byte, and the next edge emits pixel zero.
    wire pixel_cycle=(in_frame || admit_first) && !cam_vsync && cam_href && (RAW8 || byte_phase) && x<WIDTH;
    wire overflow_now=pixel_cycle && !fifo_ready;
    wire format_now=in_frame && (vsync_rise ||
                    (href_fall && ((!RAW8 && byte_phase) || x!=WIDTH)) ||
                    (!cam_vsync && cam_href && x>=WIDTH));
    wire fault_now=!fault_req && (overflow_now || format_now);
    wire [15:0] pixel=RAW8?{8'h80,cam_data}:(YUV_BYTE_ORDER==1)?{first_byte,cam_data}:{cam_data,first_byte};
    wire [18:0] fifo_input={y==HEIGHT-1 && x==WIDTH-1,x==WIDTH-1,y==0 && x==0,pixel};
    wire [18:0] fifo_output;
    camera_pixel_fifo #(.WIDTH(19),.ADDRESS_BITS(FIFO_ADDRESS_BITS)) pixel_fifo(
        .wclk(sample_clk),.rclk(core_clk),.reset_n(reset_n),.flush(fault_req),
        .wcommon_reset_n(pclk_reset_n),.rflush_active(rflush_active),
        .s_data(fifo_input),.s_valid(pixel_cycle && !fault_now && !fault_req),.s_ready(fifo_ready),
        .m_data(fifo_output),.m_valid(s_valid),.m_ready(s_ready),.queue_pressure(queue_pressure));
    assign {s_eof,s_eol,s_sof,s_data}=fifo_output;

    // All diagnostics use source-registered Gray counters. The core sees a
    // coherent delayed sample even when the two clocks are unrelated.
    reg [31:0] received_bin,dropped_bin,overflow_bin,frames_bin,bytes_bin,pixels_bin,ticks_bin;
    reg [31:0] received_gray,dropped_gray,overflow_gray,frames_gray,bytes_gray,pixels_gray,ticks_gray;
    function [31:0] gray_encode;
        input [31:0] value;
        begin gray_encode=(value>>1)^value;end
    endfunction
    function [31:0] gray_decode;
        input [31:0] value;
        integer i;
        begin
            gray_decode[31]=value[31];
            for(i=30;i>=0;i=i-1) gray_decode[i]=gray_decode[i+1]^value[i];
        end
    endfunction
    always @(posedge sample_clk or negedge pclk_reset_n) begin
        if(!pclk_reset_n) begin
            enable_sync<=0;ack_sync<=0;vsync_d<=0;href_d<=0;
            in_frame<=0;byte_phase<=0;admission_pending<=0;first_byte<=0;x<=0;y<=0;fault_req<=0;
            received_bin<=0;dropped_bin<=0;overflow_bin<=0;frames_bin<=0;
            bytes_bin<=0;pixels_bin<=0;ticks_bin<=0;
            received_gray<=0;dropped_gray<=0;overflow_gray<=0;frames_gray<=0;
            bytes_gray<=0;pixels_gray<=0;ticks_gray<=0;
        end else begin
            enable_sync<={enable_sync[0],enable};ack_sync<={ack_sync[0],fault_ack};
            vsync_d<=cam_vsync;href_d<=cam_href;
            ticks_bin<=ticks_bin+1'b1;ticks_gray<=gray_encode(ticks_bin+1'b1);
            if(cam_href && !cam_vsync) begin
                bytes_bin<=bytes_bin+1'b1;bytes_gray<=gray_encode(bytes_bin+1'b1);
            end
            if(vsync_fall) begin
                frames_bin<=frames_bin+1'b1;frames_gray<=gray_encode(frames_bin+1'b1);
            end
            if(fault_req) begin
                in_frame<=0;byte_phase<=0;admission_pending<=0;x<=0;y<=0;
                if(ack_sync[1]) fault_req<=0;
            end else if(fault_now) begin
                fault_req<=1;in_frame<=0;byte_phase<=0;admission_pending<=0;x<=0;y<=0;
                dropped_bin<=dropped_bin+1'b1;dropped_gray<=gray_encode(dropped_bin+1'b1);
                if(overflow_now) begin
                    overflow_bin<=overflow_bin+1'b1;overflow_gray<=gray_encode(overflow_bin+1'b1);
                end
            end else if(vsync_fall) begin
                byte_phase<=0;x<=0;y<=0;
                admission_pending<=ADMIT_AT_HREF;
                in_frame<=!ADMIT_AT_HREF && enable_sync[1] && !ack_sync[1];
                if(!ADMIT_AT_HREF && (!enable_sync[1] || ack_sync[1])) begin
                    dropped_bin<=dropped_bin+1'b1;dropped_gray<=gray_encode(dropped_bin+1'b1);
                end
            end else if(first_href) begin
                admission_pending<=0;in_frame<=admit_first;
                if(!admit_first) begin
                    dropped_bin<=dropped_bin+1'b1;dropped_gray<=gray_encode(dropped_bin+1'b1);
                end else if(RAW8) begin
                    x<=1;pixels_bin<=pixels_bin+1'b1;pixels_gray<=gray_encode(pixels_bin+1'b1);
                end else begin
                    first_byte<=cam_data;byte_phase<=1;
                end
            end else if(vsync_rise && admission_pending) begin
                // No HREF arrived in the armed frame. Never carry an old
                // admission decision across the next VSYNC pulse.
                admission_pending<=0;
                dropped_bin<=dropped_bin+1'b1;dropped_gray<=gray_encode(dropped_bin+1'b1);
            end else if(in_frame) begin
                if(href_fall) begin
                    byte_phase<=0;x<=0;
                    if(y==HEIGHT-1) begin
                        in_frame<=0;
                        received_bin<=received_bin+1'b1;received_gray<=gray_encode(received_bin+1'b1);
                    end else y<=y+1'b1;
                end else if(cam_href && !cam_vsync) begin
                    byte_phase<=RAW8?1'b0:!byte_phase;
                    if(!RAW8 && !byte_phase) first_byte<=cam_data;
                    else begin
                        x<=x+1'b1;
                        pixels_bin<=pixels_bin+1'b1;pixels_gray<=gray_encode(pixels_bin+1'b1);
                    end
                end
            end
        end
    end
    (* ASYNC_REG="TRUE" *) reg [1:0] req_sync,active_sync,enable_seen_sync;
    reg req_seen;
    (* ASYNC_REG="TRUE" *) reg [31:0] received_c1,received_c2,dropped_c1,dropped_c2;
    (* ASYNC_REG="TRUE" *) reg [31:0] overflow_c1,overflow_c2,frames_c1,frames_c2;
    (* ASYNC_REG="TRUE" *) reg [31:0] bytes_c1,bytes_c2,pixels_c1,pixels_c2,ticks_c1,ticks_c2;
    always @(posedge core_clk or negedge reset_n) begin
        if(!reset_n) begin
            req_sync<=0;active_sync<=0;enable_seen_sync<=0;req_seen<=0;fault_ack<=0;s_abort<=0;
            received_c1<=0;received_c2<=0;dropped_c1<=0;dropped_c2<=0;
            overflow_c1<=0;overflow_c2<=0;frames_c1<=0;frames_c2<=0;
            bytes_c1<=0;bytes_c2<=0;pixels_c1<=0;pixels_c2<=0;ticks_c1<=0;ticks_c2<=0;
        end else begin
            // rflush_active is the FIFO's sole asynchronous-fault entrance
            // into core_clk. Sample its asynchronously asserted state before
            // generating ACK/abort; release is already locally synchronized.
            req_sync<={req_sync[0],rflush_active};active_sync<={active_sync[0],in_frame};
            enable_seen_sync<={enable_seen_sync[0],enable_sync[1]};
            fault_ack<=req_sync[1];s_abort<=req_sync[1] && !req_seen;req_seen<=req_sync[1];
            received_c1<=received_gray;received_c2<=received_c1;
            dropped_c1<=dropped_gray;dropped_c2<=dropped_c1;
            overflow_c1<=overflow_gray;overflow_c2<=overflow_c1;
            frames_c1<=frames_gray;frames_c2<=frames_c1;
            bytes_c1<=bytes_gray;bytes_c2<=bytes_c1;
            pixels_c1<=pixels_gray;pixels_c2<=pixels_c1;
            ticks_c1<=ticks_gray;ticks_c2<=ticks_c1;
        end
    end
    assign capture_active=active_sync[1];
    assign admission_enabled=enable_seen_sync[1];
    assign received_frames=gray_decode(received_c2),dropped_frames=gray_decode(dropped_c2);
    assign overflow_count=gray_decode(overflow_c2),frame_sync_count=gray_decode(frames_c2);
    assign dvp_byte_count=gray_decode(bytes_c2),captured_pixels=gray_decode(pixels_c2);
    assign pclk_ticks=gray_decode(ticks_c2);
endmodule
