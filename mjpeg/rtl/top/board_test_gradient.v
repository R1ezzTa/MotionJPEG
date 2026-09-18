// Deterministic colour ramp, matching the independent JPEG model fixtures.
// YUYV: even x carries Cb; odd x carries Cr. No frame-sized pixel memory.
module board_test_gradient(input [15:0] x,y,output [15:0] pixel);
    wire [7:0] luma=x+x+x+(y<<1);
    wire [7:0] chroma=x[0] ? (x>>1)+y+y+y+16'd160 : x+y+16'd80;
    assign pixel={chroma,luma};
endmodule
