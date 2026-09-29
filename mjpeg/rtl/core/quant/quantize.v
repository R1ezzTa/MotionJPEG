// Host supplies q and ceil(2^20/q). Tables are locked throughout each JPEG.
module quantize (
    input clk,
    input rst_n,
    input cfg_valid,
    output cfg_ready,
    input busy,
    input [6:0] cfg_addr,
    input [7:0] cfg_value,
    input [20:0] cfg_recip,
    output reg tables_ready,
    output reg config_error,
    input [6:0] q_read_addr,
    output [7:0] q_read_data,
    input [31:0] s_data,
    input s_valid,
    output s_ready,
    input [1:0] s_component,
    input [4:0] s_pair,
    input s_frame_start, s_frame_end,
    output reg [31:0] m_data,
    output reg m_valid,
    input m_ready,
    output reg [1:0] m_component,
    output reg [4:0] m_pair,
    output reg m_frame_start, m_frame_end
);
    (* ram_style="distributed" *) reg [7:0] qt[0:127];
    (* ram_style="distributed" *) reg [20:0] rt[0:127];
    reg [127:0] loaded;
    // Configuration status may wait two clocks; pixel write enables must not
    // include a 128-bit reduction across the quantizer and frontend.
    (* preserve=1 *) reg [7:0] loaded_groups;
    assign cfg_ready = !busy;
    // RAM writes must be in a clock-only process. An asynchronous reset process
    // whose table entries merely hold during reset inhibits Vivado RAM inference.
    always @(posedge clk) begin
        if(rst_n && cfg_valid && cfg_ready && cfg_value!=0 && cfg_recip!=0) begin
            qt[cfg_addr]<=cfg_value;
            rt[cfg_addr]<=cfg_recip;
        end
    end
    genvar group;
    generate
        for (group = 0; group < 8; group = group + 1) begin : table_status
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) loaded_groups[group] <= 0;
                else loaded_groups[group] <= &loaded[group*16+:16];
            end
        end
    endgenerate
    assign q_read_data = qt[q_read_addr];
    wire ce = !m_valid || m_ready;
    assign s_ready = ce;
    reg v1, v2, v3, v4, v5, v6;
    reg [8:0] meta1, meta2, meta3, meta4, meta5, meta6;
    reg [37:0] prod[0:1];
    reg [16:0] num1[0:1], num2[0:1], num3[0:1], num4[0:1];
    reg [20:0] recip1[0:1];
    // ERAM clk-to-output and a split DSP multiply must not share one cycle.
    // Keep a distinct operand register between the table read and multiplier.
    (* preserve=1 *) reg [20:0] recip2[0:1];
    reg [7:0] q1[0:1], q2[0:1], q3[0:1], q4[0:1];
    reg neg1[0:1], neg2[0:1], neg3[0:1], neg4[0:1];
    reg [15:0] est[0:1];
    reg [23:0] correction_product5[0:1];
    reg [16:0] correction_num5[0:1];
    reg [15:0] signed5[0:1], signed6[0:1];
    reg adjust6[0:1], neg5[0:1], neg6[0:1];
    reg signed [16:0] signed_val;
    reg [16:0] num;
    reg [6:0] address;
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loaded <= 0;
            tables_ready <= 0;
            config_error <= 0;
            v1 <= 0;
            v2 <= 0;
            v3 <= 0;
            v4 <= 0;
            v5 <= 0;
            v6 <= 0;
            m_valid <= 0;
            m_data <= 0;
            meta1 <= 0;
            meta2 <= 0;
            meta3 <= 0;
            meta4 <= 0;
            meta5 <= 0;
            meta6 <= 0;
            m_component <= 0;
            m_pair <= 0;
            m_frame_start <= 0;
            m_frame_end <= 0;
        end else begin
            tables_ready <= &loaded_groups;
            if (cfg_valid && cfg_ready) begin
                if (cfg_value == 0 || cfg_recip == 0) config_error <= 1;
                else begin
                    loaded[cfg_addr] <= 1;
                end
            end
            if (ce) begin
                v1 <= s_valid;
                v2 <= v1;
                v3 <= v2;
                v4 <= v3;
                v5 <= v4;
                v6 <= v5;
                m_valid <= v6;
                meta1 <= {s_component, s_pair, s_frame_start, s_frame_end};
                meta2 <= meta1;
                meta3 <= meta2;
                meta4 <= meta3;
                meta5 <= meta4;
                meta6 <= meta5;
                {m_component, m_pair, m_frame_start, m_frame_end} <= meta6;
                for (i = 0; i < 2; i = i + 1) begin
                    if (s_valid) begin
                        address = {(s_component != 0), s_pair, 1'b0} + i;
                        signed_val = $signed(s_data[i*16+:16]);
                        num = (signed_val < 0 ? -signed_val : signed_val) + (qt[address] >> 1);
                        recip1[i] <= rt[address];
                        num1[i] <= num;
                        q1[i] <= qt[address];
                        neg1[i] <= signed_val < 0;
                    end
                    if (v1) begin
                        recip2[i] <= recip1[i];
                        num2[i] <= num1[i];
                        q2[i] <= q1[i];
                        neg2[i] <= neg1[i];
                    end
                    if (v2) begin
                        prod[i] <= num2[i] * recip2[i];
                        num3[i] <= num2[i];
                        q3[i] <= q2[i];
                        neg3[i] <= neg2[i];
                    end
                    if (v3) begin
                        est[i] <= prod[i] >> 20;
                        num4[i] <= num3[i];
                        q4[i] <= q3[i];
                        neg4[i] <= neg3[i];
                    end
                    if (v4) begin
                        // Separate DSP multiplication from the wide correction comparison.
                        correction_product5[i] <= est[i] * q4[i];
                        correction_num5[i] <= num4[i];
                        signed5[i] <= neg4[i] ? -est[i] : est[i];
                        neg5[i] <= neg4[i];
                    end
                    if (v5) begin
                        adjust6[i] <= correction_product5[i] > {7'd0, correction_num5[i]};
                        signed6[i] <= signed5[i];
                        neg6[i] <= neg5[i];
                    end
                    if (v6)
                        m_data[i*16+:16] <= signed6[i] +
                            (adjust6[i] ? (neg6[i] ? 16'd1 : 16'hffff) : 16'd0);
                end
            end
        end
    end
endmodule
