// Four-stage symmetric constant-matrix 1D DCT; one vector/cycle.
module dct1d (
    input clk,
    input rst_n,
    input valid,
    input [127:0] samples,
    input [3:0] tag,
    output reg result_valid,
    output [255:0] results,
    output reg [3:0] result_tag
);
    reg v1, v2, v3;
    reg [3:0] t1, t2, t3;
    reg signed [16:0] plus[0:3], minus[0:3];
    reg signed [31:0] p[0:31], b[0:15], z[0:7];
    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : outputs
            assign results[g*32+:32] = z[g];
        end
    endgenerate
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 0;
            v2 <= 0;
            v3 <= 0;
            result_valid <= 0;
            t1 <= 0;
            t2 <= 0;
            t3 <= 0;
            result_tag <= 0;
        end else begin
            v1 <= valid;
            v2 <= v1;
            v3 <= v2;
            result_valid <= v3;
            t1 <= tag;
            t2 <= t1;
            t3 <= t2;
            result_tag <= t3;
        end
    end
    always @(posedge clk) begin
        if (valid) plus[0] <= $signed(samples[0+:16]) + $signed(samples[112+:16]);
        if (valid) minus[0] <= $signed(samples[0+:16]) - $signed(samples[112+:16]);
        if (valid) plus[1] <= $signed(samples[16+:16]) + $signed(samples[96+:16]);
        if (valid) minus[1] <= $signed(samples[16+:16]) - $signed(samples[96+:16]);
        if (valid) plus[2] <= $signed(samples[32+:16]) + $signed(samples[80+:16]);
        if (valid) minus[2] <= $signed(samples[32+:16]) - $signed(samples[80+:16]);
        if (valid) plus[3] <= $signed(samples[48+:16]) + $signed(samples[64+:16]);
        if (valid) minus[3] <= $signed(samples[48+:16]) - $signed(samples[64+:16]);
        if (v1) p[0] <= plus[0] * 13'sd1448;
        if (v1) p[1] <= plus[1] * 13'sd1448;
        if (v1) p[2] <= plus[2] * 13'sd1448;
        if (v1) p[3] <= plus[3] * 13'sd1448;
        if (v1) p[4] <= minus[0] * 13'sd2009;
        if (v1) p[5] <= minus[1] * 13'sd1703;
        if (v1) p[6] <= minus[2] * 13'sd1138;
        if (v1) p[7] <= minus[3] * 13'sd400;
        if (v1) p[8] <= plus[0] * 13'sd1892;
        if (v1) p[9] <= plus[1] * 13'sd784;
        if (v1) p[10] <= plus[2] * -13'sd784;
        if (v1) p[11] <= plus[3] * -13'sd1892;
        if (v1) p[12] <= minus[0] * 13'sd1703;
        if (v1) p[13] <= minus[1] * -13'sd400;
        if (v1) p[14] <= minus[2] * -13'sd2009;
        if (v1) p[15] <= minus[3] * -13'sd1138;
        if (v1) p[16] <= plus[0] * 13'sd1448;
        if (v1) p[17] <= plus[1] * -13'sd1448;
        if (v1) p[18] <= plus[2] * -13'sd1448;
        if (v1) p[19] <= plus[3] * 13'sd1448;
        if (v1) p[20] <= minus[0] * 13'sd1138;
        if (v1) p[21] <= minus[1] * -13'sd2009;
        if (v1) p[22] <= minus[2] * 13'sd400;
        if (v1) p[23] <= minus[3] * 13'sd1703;
        if (v1) p[24] <= plus[0] * 13'sd784;
        if (v1) p[25] <= plus[1] * -13'sd1892;
        if (v1) p[26] <= plus[2] * 13'sd1892;
        if (v1) p[27] <= plus[3] * -13'sd784;
        if (v1) p[28] <= minus[0] * 13'sd400;
        if (v1) p[29] <= minus[1] * -13'sd1138;
        if (v1) p[30] <= minus[2] * 13'sd1703;
        if (v1) p[31] <= minus[3] * -13'sd2009;
        if (v2) b[0] <= p[0] + p[1];
        if (v2) b[1] <= p[2] + p[3];
        if (v3) z[0] <= b[0] + b[1];
        if (v2) b[2] <= p[4] + p[5];
        if (v2) b[3] <= p[6] + p[7];
        if (v3) z[1] <= b[2] + b[3];
        if (v2) b[4] <= p[8] + p[9];
        if (v2) b[5] <= p[10] + p[11];
        if (v3) z[2] <= b[4] + b[5];
        if (v2) b[6] <= p[12] + p[13];
        if (v2) b[7] <= p[14] + p[15];
        if (v3) z[3] <= b[6] + b[7];
        if (v2) b[8] <= p[16] + p[17];
        if (v2) b[9] <= p[18] + p[19];
        if (v3) z[4] <= b[8] + b[9];
        if (v2) b[10] <= p[20] + p[21];
        if (v2) b[11] <= p[22] + p[23];
        if (v3) z[5] <= b[10] + b[11];
        if (v2) b[12] <= p[24] + p[25];
        if (v2) b[13] <= p[26] + p[27];
        if (v3) z[6] <= b[12] + b[13];
        if (v2) b[14] <= p[28] + p[29];
        if (v2) b[15] <= p[30] + p[31];
        if (v3) z[7] <= b[14] + b[15];
    end
endmodule
