// Board-sized synthesis wrapper. The JPEG IP retains its 128-bit DMA interface.
// This 32-bit adapter is useful for inspection and standalone functional tests.
module jpeg_synth_top #(
    parameter MAX_WIDTH = 1920
) (
    input clk,
    input rst_n,
    input [15:0] cfg_width, cfg_height,
    input cfg_gray,
    input cfg_q_valid,
    output cfg_q_ready,
    input [6:0] cfg_q_addr,
    input [7:0] cfg_q_value,
    input [20:0] cfg_q_recip,
    output tables_ready,
    input [15:0] s_data,
    input s_valid,
    output s_ready,
    input s_sof, s_eol, s_eof,
    output [31:0] m_data,
    output [2:0] m_bytes,
    output m_valid,
    input m_ready,
    output m_last,
    output busy, protocol_error, config_error, coefficient_error
);
    wire [127:0] word;
    wire [4:0] word_bytes;
    wire word_valid, word_last;
    reg [127:0] buffer;
    reg [4:0] remaining;
    reg valid, last;
    wire final_chunk = remaining <= 4;
    wire ready = !valid || (m_ready && final_chunk);
    wire adapter_hold = valid && last;
    wire core_busy, core_s_ready, core_q_ready;
    assign busy = core_busy || adapter_hold;
    assign s_ready = core_s_ready && !adapter_hold;
    assign cfg_q_ready = core_q_ready && !adapter_hold;
    assign m_data = buffer[31:0];
    assign m_bytes = final_chunk ? remaining[2:0] : 3'd4;
    assign m_valid = valid;
    assign m_last = last && final_chunk;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buffer <= 0;
            remaining <= 0;
            valid <= 0;
            last <= 0;
        end else begin
            if (valid && m_ready) begin
                if (final_chunk) valid <= 0;
                else begin
                    buffer <= buffer >> 32;
                    remaining <= remaining - 4;
                end
            end
            if (word_valid && ready) begin
                buffer <= word;
                remaining <= word_bytes;
                valid <= 1;
                last <= word_last;
            end
        end
    end
    jpeg_encoder #(
        .MAX_WIDTH(MAX_WIDTH)
    ) core (
        .clk              (clk),
        .rst_n            (rst_n),
        .cfg_width        (cfg_width),
        .cfg_height       (cfg_height),
        .cfg_gray         (cfg_gray),
        .cfg_q_valid      (cfg_q_valid && !adapter_hold),
        .cfg_q_ready      (core_q_ready),
        .cfg_q_addr       (cfg_q_addr),
        .cfg_q_value      (cfg_q_value),
        .cfg_q_recip      (cfg_q_recip),
        .tables_ready     (tables_ready),
        .s_data           (s_data),
        .s_valid          (s_valid && !adapter_hold),
        .s_ready          (core_s_ready),
        .s_sof            (s_sof),
        .s_eol            (s_eol),
        .s_eof            (s_eof),
        .m_data           (word),
        .m_bytes          (word_bytes),
        .m_valid          (word_valid),
        .m_ready          (ready),
        .m_last           (word_last),
        .busy             (core_busy),
        .protocol_error   (protocol_error),
        .config_error     (config_error),
        .coefficient_error(coefficient_error)
    );
endmodule
