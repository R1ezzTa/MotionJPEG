// Dual-clock FIFO: Gray pointers, two-stage synchronizers and synchronous RAM.
// Both domains must share the same asynchronous reset event. Release is local.
// The registered front word is stable while valid && !ready, including full.
module board_test_async_fifo #(
    parameter WIDTH=8, ADDRESS_BITS=13, RAM_STYLE="block"
)(
    input wclk,wrst_n,input [WIDTH-1:0] s_data,input s_valid,output s_ready,
    input rclk,rrst_n,output reg [WIDTH-1:0] m_data,output m_valid,input m_ready
);
    localparam POINTER_BITS=ADDRESS_BITS+1;
    (* ram_style=RAM_STYLE *) reg [WIDTH-1:0] memory[0:(1<<ADDRESS_BITS)-1];
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
    // No reset on memory ports, so Vivado can infer a true dual-clock BRAM.
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
