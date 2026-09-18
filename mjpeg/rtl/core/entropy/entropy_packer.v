// Bit buffer, two-stage alignment, FF prefix positions and byte scatter.
// Each stage can accept one group/cycle; output stalls freeze the pipeline.
module entropy_packer (
    input clk,
    input rst_n,
    input [127:0] s_bits,
    input [7:0] s_length,
    input s_frame_end, s_valid,
    output s_ready,
    output reg [127:0] m_data,
    output reg [4:0] m_bytes,
    output reg m_frame_end, m_valid,
    input m_ready
);
    reg [127:0] reservoir;
    reg [7:0] count;
    reg ending, padding;
    reg [2:0] pad_bits;
    wire ce = !m_valid || m_ready;
    // A legal two-coefficient group has at most 3 ZRLs and 2 values:
    // 3*16 + 2*(16+10) = 100 bits. Reserve that space after draining bytes.
    reg [127:0] next_buf;
    reg [7:0] next_count;
    reg next_end, next_padding;
    wire [3:0] raw_count = count >= 64 ? 4'd8 : count[6:3];
    wire [7:0] remainder = count >= 64 ? {count[7:6] - 2'd1, count[5:0]} : {5'd0, count[2:0]};
    // For count<64 the remainder is at most 7; otherwise it is count-64.
    // Thus count<=92 is exactly the same space test, with no subtractor.
    assign s_ready = ce && !ending && !padding && (count <= 92);
    // ce already guards the sequential updates. Keep it out of the data
    // selection logic to avoid repeating the downstream ready path.
    wire take_group = s_valid && !ending && !padding && (count <= 92);
    wire [2:0] tail_bits = remainder[2:0] + s_length[2:0];
    wire emit = (raw_count != 0) || ending;
    wire last = ending && (remainder == 0);
    reg v0, v1, v2, v3, v4, e0, e1, e2, e3, e4;
    reg [127:0] raw_buffer0;
    reg [7:0] alignment0;
    reg [3:0] n0;
    reg [127:0] aligned_low;
    reg [3:0] align_high;
    reg [63:0] raw2, raw3, raw4;
    reg [3:0] n1, n2, n3, n4;
    reg [7:0] ff3;
    reg [3:0] positions[0:7];
    reg [4:0] bytes4;
    reg [127:0] packed;
    integer i;
    function [3:0] popcount;
        input [7:0] value;
        reg [1:0] a, b, c, d;
        reg [2:0] ab, cd;
        begin
            a = {1'b0, value[0]} + value[1];
            b = {1'b0, value[2]} + value[3];
            c = {1'b0, value[4]} + value[5];
            d = {1'b0, value[6]} + value[7];
            ab = {1'b0, a} + b;
            cd = {1'b0, c} + d;
            popcount = {1'b0, ab} + cd;
        end
    endfunction
    always @* begin
        next_buf = reservoir;
        next_count = remainder;
        next_end = ending;
        next_padding = padding;
        if (last) next_end = 0;
        if (take_group) begin
            // Legal Huffman groups are <=100 bits, so bit 7 cannot be set.
            // Do not synthesize an unnecessary >=128 shift/zero selection stage.
            // Acceptance guarantees remainder<=28 after draining. Higher old bits
            // are already emitted and cannot contribute to the new valid count.
            next_buf = ({100'd0, reservoir[27:0]} << s_length[6:0]) | s_bits;
            next_count = remainder + s_length;
            if (s_frame_end) next_padding = 1;
        end else if (padding) begin
            // Padding gets its own clock so the residue count does not control
            // the full-width normal append shifter through two extra adders.
            next_buf = (next_buf << pad_bits) | ((128'd1 << pad_bits) - 1'b1);
            next_count = remainder + pad_bits;
            next_padding = 0;
            next_end = 1;
        end
    end
    always @* begin
        packed = 0;
        for (i = 0; i < 8; i = i + 1)
        if (i < n4) packed[positions[i]*8+:8] = raw4[63-i*8-:8];
    end
    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reservoir <= 0;
            count <= 0;
            ending <= 0;
            padding <= 0;
            pad_bits <= 0;
            m_data <= 0;
            m_bytes <= 0;
            m_frame_end <= 0;
            m_valid <= 0;
            v0 <= 0;
            e0 <= 0;
            raw_buffer0 <= 0;
            alignment0 <= 128;
            n0 <= 0;
            v1 <= 0;
            v2 <= 0;
            v3 <= 0;
            v4 <= 0;
            e1 <= 0;
            e2 <= 0;
            e3 <= 0;
            e4 <= 0;
            aligned_low <= 0;
            align_high <= 0;
            raw2 <= 0;
            raw3 <= 0;
            raw4 <= 0;
            n1 <= 0;
            n2 <= 0;
            n3 <= 0;
            n4 <= 0;
            ff3 <= 0;
            bytes4 <= 0;
            for (j = 0; j < 8; j = j + 1) positions[j] <= 0;
        end else if (ce) begin
            reservoir <= next_buf;
            count <= next_count;
            ending <= next_end;
            padding <= next_padding;
            if (s_valid && s_ready && s_frame_end) pad_bits <= -tail_bits;
            v0 <= emit;
            v1 <= v0;
            v2 <= v1;
            v3 <= v2;
            v4 <= v3;
            m_valid <= v4;
            e0 <= last;
            e1 <= e0;
            e2 <= e1;
            e3 <= e2;
            e4 <= e3;
            m_frame_end <= e4;
            n0 <= raw_count;
            n1 <= n0;
            n2 <= n1;
            n3 <= n2;
            n4 <= n3;
            if (emit) begin
                raw_buffer0 <= reservoir;
                alignment0 <= 8'd128 - count;
            end
            if (v0) begin
                aligned_low <= raw_buffer0 << alignment0[3:0];
                align_high <= alignment0[7:4];
            end
            if (v1) raw2 <= (aligned_low << {align_high, 4'd0}) >> 64;
            if (v2) begin
                raw3 <= raw2;
                for (j = 0; j < 8; j = j + 1) ff3[j] <= (j < n2) && (raw2[63-j*8-:8] == 255);
            end
            if (v3) begin
                raw4 <= raw3;
                bytes4 <= {1'b0, n3} + popcount(ff3);
                for (j = 0; j < 8; j = j + 1) positions[j] <= j + popcount(ff3 & ((8'd1 << j) - 1));
            end
            if (v4) begin
                m_data <= packed;
                m_bytes <= bytes4;
            end
        end
    end
endmodule
