// Lookup, table selection, amplitude append, then balanced concatenation.
// One symbol group is accepted per clock; output stalls freeze all stages.
module huffman_encoder (
    input clk,
    input rst_n,
    input [39:0] s_symbols,
    input [54:0] s_amplitudes,
    input [19:0] s_sizes,
    input [4:0] s_dc,
    input [2:0] s_count,
    input s_chroma, s_frame_end, s_valid,
    output s_ready,
    output reg [127:0] m_bits,
    output reg [7:0] m_length  /* synthesis max_fanout=32 */,
    output reg m_frame_end, m_valid,
    input m_ready
);
    `include "rtl/generated/huffman.vh"
    wire ce = !m_valid || m_ready;
    assign s_ready = ce;
    reg va, vb, v1, v2, v3, ea, eb, e1, e2, e3;
    (* rom_style="block" *) reg [20:0] lookup_rom[0:1023];
    reg [20:0] lookup_q[0:4],chosen[0:4];
    integer init_key;
    initial for(init_key=0;init_key<1024;init_key=init_key+1)
        lookup_rom[init_key]=huffman(init_key);
    reg [10:0] amp_a[0:4], amp_b[0:4];
    reg [3:0] size_a[0:4], size_b[0:4];
    reg [4:0] dc_a, active_a, active_b;
    reg chroma_a;
    reg [25:0] code1[0:4];
    reg [4:0] len1[0:4];
    reg [51:0] pair01, pair23;
    reg [5:0] len01, len23;
    reg [25:0] code4_2, code4_3;
    reg [4:0] len4_2, len4_3;
    reg [103:0] group03;
    reg [6:0] len03;
    integer j;
    genvar lane;
    generate for(lane=0;lane<5;lane=lane+1) begin: rom_lanes
        wire [7:0] symbol=s_dc[lane]?{4'd0,s_symbols[lane*8+:4]}:s_symbols[lane*8+:8];
        // Pure synchronous read, no asynchronous output reset, so the unified
        // YDC/YAC/CDC/CAC lookup maps directly into one BRAM per lane.
        always @(posedge clk)
            if(ce && s_valid) lookup_q[lane]<=lookup_rom[{s_chroma,!s_dc[lane],symbol}];
    end endgenerate
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            va <= 0;
            vb <= 0;
            v1 <= 0;
            v2 <= 0;
            v3 <= 0;
            ea <= 0;
            eb <= 0;
            e1 <= 0;
            e2 <= 0;
            e3 <= 0;
            dc_a <= 0;
            active_a <= 0;
            active_b <= 0;
            chroma_a <= 0;
            m_bits <= 0;
            m_length <= 0;
            m_frame_end <= 0;
            m_valid <= 0;
            pair01 <= 0;
            pair23 <= 0;
            len01 <= 0;
            len23 <= 0;
            code4_2 <= 0;
            code4_3 <= 0;
            len4_2 <= 0;
            len4_3 <= 0;
            group03 <= 0;
            len03 <= 0;
            for (j = 0; j < 5; j = j + 1) begin
                code1[j] <= 0;
                len1[j] <= 0;
                chosen[j] <= 0;
                amp_a[j] <= 0;
                amp_b[j] <= 0;
                size_a[j] <= 0;
                size_b[j] <= 0;
            end
        end else if (ce) begin
            va <= s_valid;
            vb <= va;
            v1 <= vb;
            v2 <= v1;
            v3 <= v2;
            m_valid <= v3;
            ea <= s_frame_end;
            eb <= ea;
            e1 <= eb;
            e2 <= e1;
            e3 <= e2;
            m_frame_end <= e3;
            if (s_valid)
                for (j = 0; j < 5; j = j + 1) begin
                    amp_a[j] <= s_amplitudes[j*11+:11];
                    size_a[j] <= s_sizes[j*4+:4];
                    active_a[j] <= j < s_count;
                end
            if (s_valid) begin
                dc_a <= s_dc;
                chroma_a <= s_chroma;
            end
            if (va)
                for (j = 0; j < 5; j = j + 1) begin
                    chosen[j] <= lookup_q[j];
                    amp_b[j] <= amp_a[j];
                    size_b[j] <= size_a[j];
                    active_b[j] <= active_a[j];
                end
            if (vb)
                for (j = 0; j < 5; j = j + 1) begin
                    code1[j] <= active_b[j] ? (({10'd0, chosen[j][15:0]} << size_b[j]) | amp_b[j]) :
                        26'd0;
                    len1[j] <= active_b[j] ? chosen[j][20:16] + size_b[j] : 5'd0;
                end
            if (v1) begin
                pair01 <= ({26'd0, code1[0]} << len1[1]) | code1[1];
                len01 <= {1'b0, len1[0]} + len1[1];
                pair23 <= ({26'd0, code1[2]} << len1[3]) | code1[3];
                len23 <= {1'b0, len1[2]} + len1[3];
                code4_2 <= code1[4];
                len4_2 <= len1[4];
            end
            if (v2) begin
                group03 <= ({52'd0, pair01} << len23) | pair23;
                len03 <= {1'b0, len01} + len23;
                code4_3 <= code4_2;
                len4_3 <= len4_2;
            end
            if (v3) begin
                m_bits <= ({24'd0, group03} << len4_3) | code4_3;
                m_length <= {1'b0, len03} + len4_3;
            end
        end
    end
endmodule
