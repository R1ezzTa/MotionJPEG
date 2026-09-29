// Pixel CDC FIFO. reset_n and flush are separate common asynchronous events.
// Both assert immediately; each clock domain releases them after three local
// edges. Keeping the two synchronizers separate avoids reset-cone CDC logic.
// Depth must be a power of two.
module camera_pixel_fifo #(
    parameter WIDTH=19, ADDRESS_BITS=12
)(
    input wclk,input rclk,input reset_n,input flush,
    output wcommon_reset_n,output rflush_active,
    input [WIDTH-1:0] s_data,input s_valid,output s_ready,
    output reg [WIDTH-1:0] m_data,output m_valid,input m_ready,
    output reg queue_pressure
);
    localparam POINTER_BITS=ADDRESS_BITS+1;
    (* ASYNC_REG="TRUE" *) reg [2:0] wreset_pipe=0,rreset_pipe=0;
    always @(posedge wclk or negedge reset_n)
        if(!reset_n) wreset_pipe<=0;else wreset_pipe<={wreset_pipe[1:0],1'b1};
    always @(posedge rclk or negedge reset_n)
        if(!reset_n) rreset_pipe<=0;else rreset_pipe<={rreset_pipe[1:0],1'b1};
    (* ASYNC_REG="TRUE" *) reg [2:0] wflush_pipe=0,rflush_pipe=0;
    // No global reset on these preset synchronizers: global reset is handled
    // by reset_pipe and masks any pending flush while either clock is absent.
    always @(posedge wclk or posedge flush)
        if(flush) wflush_pipe<=3'b111;
        else wflush_pipe<={wflush_pipe[1:0],1'b0};
    always @(posedge rclk or posedge flush)
        if(flush) rflush_pipe<=3'b111;
        else rflush_pipe<={rflush_pipe[1:0],1'b0};
    // Share each asynchronous source's one synchronizer entrance with the
    // capture controller; do not create parallel chains in the same domain.
    assign wcommon_reset_n=wreset_pipe[2];
    assign rflush_active=rflush_pipe[2];
    wire wrst_n=wreset_pipe[2] && !wflush_pipe[2];
    wire rrst_n=rreset_pipe[2] && !rflush_pipe[2];
    (* ram_style="block" *) reg [WIDTH-1:0] memory[0:(1<<ADDRESS_BITS)-1];
    reg [POINTER_BITS-1:0] wbin,wgray,rbin,rgray;
    (* ASYNC_REG="TRUE" *) reg [POINTER_BITS-1:0] rgray_w1,rgray_w2,wgray_r1,wgray_r2;
    reg full,empty;
    assign s_ready=wrst_n && !full;
    assign m_valid=rrst_n && !empty;
    wire write_fire=s_valid && s_ready,read_fire=m_valid && m_ready;
    wire [POINTER_BITS-1:0] wnext=wbin+write_fire,rnext=rbin+read_fire;
    wire [POINTER_BITS-1:0] wgray_next=(wnext>>1)^wnext,rgray_next=(rnext>>1)^rnext;
    wire full_next=wgray_next=={~rgray_w2[POINTER_BITS-1:POINTER_BITS-2],rgray_w2[POINTER_BITS-3:0]};
    wire empty_next=rgray_next==wgray_r2;
    function [POINTER_BITS-1:0] gray_binary;
        input [POINTER_BITS-1:0] value;integer bit_index;
        begin
            gray_binary[POINTER_BITS-1]=value[POINTER_BITS-1];
            for(bit_index=POINTER_BITS-2;bit_index>=0;bit_index=bit_index-1)
                gray_binary[bit_index]=gray_binary[bit_index+1]^value[bit_index];
        end
    endfunction
    // Read-domain water level uses only the already synchronized Gray write
    // pointer. The small CDC observation delay leaves three quarters of the
    // FIFO free before overflow; no unsynchronized binary bus is introduced.
    wire [POINTER_BITS-1:0] queued=gray_binary(wgray_r2)-rbin;
    always @(posedge rclk or negedge rrst_n)
        if(!rrst_n) queue_pressure<=0;
        else queue_pressure<=queued>=(1<<(ADDRESS_BITS-2));
    always @(posedge wclk) if(write_fire) memory[wbin[ADDRESS_BITS-1:0]]<=s_data;
    always @(posedge rclk) if(rrst_n && !empty_next) m_data<=memory[rnext[ADDRESS_BITS-1:0]];
    always @(posedge wclk or negedge wrst_n) begin
        if(!wrst_n) begin wbin<=0;wgray<=0;rgray_w1<=0;rgray_w2<=0;full<=0;end
        else begin
            rgray_w1<=rgray;rgray_w2<=rgray_w1;
            wbin<=wnext;wgray<=wgray_next;full<=full_next;
        end
    end
    always @(posedge rclk or negedge rrst_n) begin
        if(!rrst_n) begin rbin<=0;rgray<=0;wgray_r1<=0;wgray_r2<=0;empty<=1;end
        else begin
            wgray_r1<=wgray;wgray_r2<=wgray_r1;
            rbin<=rnext;rgray<=rgray_next;empty<=empty_next;
        end
    end
endmodule
