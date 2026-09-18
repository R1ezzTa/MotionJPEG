// DC difference, magnitude/category, then bounded AC run-length coding.
// Two coefficients can produce up to three ZRLs and two value symbols.
module symbol_encoder (
    input clk,
    input rst_n,
    input [31:0] s_data,
    input s_valid,
    output s_ready,
    input [1:0] s_component,
    input [4:0] s_pair,
    input s_frame_start, s_frame_end,
    output reg [39:0] m_symbols,
    output reg [54:0] m_amplitudes,
    output reg [19:0] m_sizes,
    output reg [4:0] m_dc,
    output reg [2:0] m_count,
    output reg m_chroma, m_frame_end,
    output reg m_valid,
    input m_ready,
    output reg coefficient_error
);
    reg signed [15:0] previous[0:2];
    reg [5:0] run;
    wire ce = !m_valid || m_ready;
    assign s_ready = ce;
    reg v1, v2;
    reg [33:0] values1;
    reg [4:0] pair1, pair2;
    reg chroma1, chroma2, start1, start2, end1, end2;
    reg [21:0] amps2;
    reg [9:0] categories2;
    reg [1:0] zero2;
    reg err2;
    function [4:0] category;
        input [16:0] magnitude;
        integer bit_index;
        begin
            category = 0;
            for (bit_index = 0; bit_index < 17; bit_index = bit_index + 1)
            if (magnitude[bit_index]) category = bit_index + 1;
        end
    endfunction
    reg signed [16:0] value;
    reg [16:0] magnitude;
    reg [4:0] size;
    reg [21:0] amps;
    reg [9:0] categories;
    reg [1:0] zeros;
    reg err;
    integer lane;
    always @* begin
        amps = 0;
        categories = 0;
        zeros = 0;
        err = 0;
        value = 0;
        magnitude = 0;
        size = 0;
        for (lane = 0; lane < 2; lane = lane + 1) begin
            value = $signed(values1[lane*17+:17]);
            magnitude = value < 0 ? -value : value;
            size = category(magnitude);
            categories[lane*5+:5] = size;
            zeros[lane] = (value == 0);
            // Category is registered before applying its 11-bit amplitude mask.
            // Negative JPEG amplitudes equal value-1.
            amps[lane*11+:11] = value < 0 ? value - 17'sd1 : value;
            if (pair1 == 0 && lane == 0) begin
                if (|magnitude[16:11]) err = 1;
            end else if (|magnitude[16:10]) err = 1;
        end
    end
    reg [39:0] symbols;
    reg [54:0] amplitudes;
    reg [19:0] sizes;
    reg [4:0] dc;
    reg [5:0] pending_run;
    reg [2:0] cnt;
    integer pos, k, lane2;
    always @* begin
        symbols = 0;
        amplitudes = 0;
        sizes = 0;
        dc = 0;
        cnt = 0;
        pending_run = run;
        pos = 0;
        for (lane2 = 0; lane2 < 2; lane2 = lane2 + 1) begin
            pos = pair2 * 2 + lane2;
            if (pos == 0) begin
                pending_run = 0;
                symbols[cnt*8+:8] = {3'd0, categories2[lane2*5+:5]};
                amplitudes[cnt*11+:11] = amps2[lane2*11+:11] &
                    ((11'd1 << categories2[lane2*5+:5]) - 1'b1);
                sizes[cnt*4+:4] = categories2[lane2*5+:4];
                dc[cnt] = 1;
                cnt = cnt + 1'b1;
            end else if (zero2[lane2]) begin
                pending_run = pending_run + 1'b1;
                if (pos == 63) begin
                    symbols[cnt*8+:8] = 0;
                    cnt = cnt + 1'b1;
                    pending_run = 0;
                end
            end else begin
                for (k = 0; k < 3; k = k + 1)
                if (k < pending_run[5:4]) begin
                    symbols[cnt*8+:8] = 8'hf0;
                    cnt = cnt + 1'b1;
                end
                symbols[cnt*8+:8] = {pending_run[3:0], categories2[lane2*5+:4]};
                amplitudes[cnt*11+:11] = amps2[lane2*11+:11] &
                    ((11'd1 << categories2[lane2*5+:5]) - 1'b1);
                sizes[cnt*4+:4] = categories2[lane2*5+:4];
                cnt = cnt + 1'b1;
                pending_run = 0;
            end
        end
    end
    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            previous[0] <= 0;
            previous[1] <= 0;
            previous[2] <= 0;
            run <= 0;
            coefficient_error <= 0;
            v1 <= 0;
            v2 <= 0;
            values1 <= 0;
            pair1 <= 0;
            pair2 <= 0;
            chroma1 <= 0;
            chroma2 <= 0;
            start1 <= 0;
            start2 <= 0;
            end1 <= 0;
            end2 <= 0;
            amps2 <= 0;
            categories2 <= 0;
            zero2 <= 0;
            err2 <= 0;
            m_symbols <= 0;
            m_amplitudes <= 0;
            m_sizes <= 0;
            m_dc <= 0;
            m_count <= 0;
            m_chroma <= 0;
            m_frame_end <= 0;
            m_valid <= 0;
        end else if (ce) begin
            v1 <= s_valid;
            v2 <= v1;
            m_valid <= v2;
            if (s_valid) begin
                values1[16:0] <= s_pair == 0 ? $signed(
                    s_data[15:0]
                ) - (s_frame_start ? 17'sd0 : $signed(
                    previous[s_component]
                )) : $signed(
                    s_data[15:0]
                );
                values1[33:17] <= $signed(s_data[31:16]);
                pair1 <= s_pair;
                chroma1 <= s_component != 0;
                start1 <= s_frame_start;
                end1 <= s_frame_end;
                if (s_frame_start) for (j = 0; j < 3; j = j + 1) previous[j] <= 0;
                if (s_pair == 0) previous[s_component] <= s_data[15:0];
            end
            if (v1) begin
                amps2 <= amps;
                categories2 <= categories;
                zero2 <= zeros;
                err2 <= err;
                pair2 <= pair1;
                chroma2 <= chroma1;
                start2 <= start1;
                end2 <= end1;
            end
            if (v2) begin
                run <= pending_run;
                m_symbols <= symbols;
                m_amplitudes <= amplitudes;
                m_sizes <= sizes;
                m_dc <= dc;
                m_count <= cnt;
                m_chroma <= chroma2;
                m_frame_end <= end2;
                if (start2) coefficient_error <= err2;
                else if (err2) coefficient_error <= 1;
            end
        end
    end
endmodule
