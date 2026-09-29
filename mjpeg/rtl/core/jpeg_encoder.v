// Baseline sequential JPEG, 8-bit grayscale or full-range YUYV 4:2:2.
// Byte 0 is m_data[7:0]; m_bytes valid contiguous bytes; m_last carries EOI.
module jpeg_encoder #(
    parameter MAX_WIDTH = 1920, RESTART_MCUS=0
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
    output [127:0] m_data,
    output [4:0] m_bytes,
    output m_valid,
    input m_ready,
    output m_last,
    output reg busy,
    output protocol_error, config_error, coefficient_error
);
    reg [15:0] width, height;
    reg gray, input_done;
    // Header startup need not share the pixel-acceptance combinational path.
    // Delay only its trigger; busy and frame geometry still latch at first pixel.
    reg formatter_start;
    wire a_ready, a_valid;
    wire [15:0] a_data;
    wire [1:0] ac;
    wire [4:0] ap;
    wire afs, afe;
    wire b_ready, b_valid;
    wire [31:0] b_data;
    wire [1:0] bc;
    wire [4:0] bp;
    wire bfs, bfe;
    wire c_ready, c_valid;
    wire [31:0] c_data;
    wire [1:0] cc;
    wire [4:0] cp;
    wire cfs, cfe;
    wire d_ready, d_valid;
    wire [31:0] d_data;
    wire [1:0] dc;
    wire [4:0] dp;
    wire dfs, dfe;
    wire e_ready, e_valid;
    wire [39:0] symbols;
    wire [54:0] amplitudes;
    wire [19:0] sizes;
    wire [4:0] flags;
    wire [2:0] symbol_count;
    wire chroma, efe;
    wire f_ready, f_valid;
    wire [127:0] bits;
    wire [7:0] bit_length;
    wire ffe;
    wire g_ready, g_valid;
    wire [127:0] entropy;
    wire [4:0] entropy_bytes;
    wire gfe;
    wire front_ready, input_frame_end;
    wire [133:0] formatter_input;
    wire formatter_input_valid, formatter_input_ready;
    wire allow = tables_ready && (busy || !cfg_q_valid) && !input_done;
    assign s_ready = front_ready && allow;
    wire start = s_valid && s_ready && !busy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 0;
            width <= 0;
            height <= 0;
            gray <= 1;
            input_done <= 0;
            formatter_start <= 0;
        end else begin
            formatter_start <= start;
            if (start) begin
                busy <= 1;
                width <= cfg_width;
                height <= cfg_height;
                gray <= cfg_gray;
            end
            if (input_frame_end) input_done <= 1;
            if (m_valid && m_ready && m_last) begin
                busy <= 0;
                input_done <= 0;
            end
        end
    end
    raster_to_mcu422 #(
        .MAX_WIDTH(MAX_WIDTH)
    ) front (
        .clk            (clk),
        .rst_n          (rst_n),
        .cfg_width      (cfg_width),
        .cfg_height     (cfg_height),
        .cfg_gray       (cfg_gray),
        .s_data         (s_data),
        .s_valid        (s_valid && allow),
        .s_ready        (front_ready),
        .s_sof          (s_sof),
        .s_eol          (s_eol),
        .s_eof          (s_eof),
        .m_data         (a_data),
        .m_valid        (a_valid),
        .m_ready        (a_ready),
        .m_component    (ac),
        .m_pair         (ap),
        .m_frame_start  (afs),
        .m_frame_end    (afe),
        .protocol_error (protocol_error),
        .input_frame_end(input_frame_end)
    );
    dct8x8 dct (
        .clk          (clk),
        .rst_n        (rst_n),
        .s_data       (a_data),
        .s_valid      (a_valid),
        .s_ready      (a_ready),
        .s_component  (ac),
        .s_pair       (ap),
        .s_frame_start(afs),
        .s_frame_end  (afe),
        .m_data       (b_data),
        .m_valid      (b_valid),
        .m_ready      (b_ready),
        .m_component  (bc),
        .m_pair       (bp),
        .m_frame_start(bfs),
        .m_frame_end  (bfe)
    );
    wire [6:0] q_addr;
    wire [7:0] q_data;
    quantize quant (
        .clk          (clk),
        .rst_n        (rst_n),
        .cfg_valid    (cfg_q_valid),
        .cfg_ready    (cfg_q_ready),
        .busy         (busy),
        .cfg_addr     (cfg_q_addr),
        .cfg_value    (cfg_q_value),
        .cfg_recip    (cfg_q_recip),
        .tables_ready (tables_ready),
        .config_error (config_error),
        .q_read_addr  (q_addr),
        .q_read_data  (q_data),
        .s_data       (b_data),
        .s_valid      (b_valid),
        .s_ready      (b_ready),
        .s_component  (bc),
        .s_pair       (bp),
        .s_frame_start(bfs),
        .s_frame_end  (bfe),
        .m_data       (c_data),
        .m_valid      (c_valid),
        .m_ready      (c_ready),
        .m_component  (cc),
        .m_pair       (cp),
        .m_frame_start(cfs),
        .m_frame_end  (cfe)
    );
    zigzag_buffer scan_order (
        .clk          (clk),
        .rst_n        (rst_n),
        .s_data       (c_data),
        .s_valid      (c_valid),
        .s_ready      (c_ready),
        .s_component  (cc),
        .s_pair       (cp),
        .s_frame_start(cfs),
        .s_frame_end  (cfe),
        .m_data       (d_data),
        .m_valid      (d_valid),
        .m_ready      (d_ready),
        .m_component  (dc),
        .m_pair       (dp),
        .m_frame_start(dfs),
        .m_frame_end  (dfe)
    );
    // Restart groups follow spatial MCU order. Quantized coefficients and
    // original SOF remain unchanged; only DC prediction/entropy boundaries reset.
    reg [15:0] interval_mcus;
    reg [1:0] interval_block;
    wire last_mcu_pair = dp==31 && (gray || interval_block==3);
    wire interval_end = RESTART_MCUS!=0 && last_mcu_pair &&
        (interval_mcus==RESTART_MCUS-1 || dfe);
    wire interval_start = RESTART_MCUS!=0 && dp==0 && interval_block==0 && interval_mcus==0;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin interval_mcus<=0;interval_block<=0;end
        else if(d_valid && d_ready && dp==31) begin
            if(last_mcu_pair) begin
                interval_block<=0;
                interval_mcus<=(interval_end || dfe)?0:interval_mcus+1'b1;
            end else interval_block<=interval_block+1'b1;
        end
    end
    symbol_encoder #(.RESTART_ENABLE(RESTART_MCUS!=0)) symbols_core (
        .clk              (clk),
        .rst_n            (rst_n),
        .s_data           (d_data),
        .s_valid          (d_valid),
        .s_ready          (d_ready),
        .s_component      (dc),
        .s_pair           (dp),
        .s_frame_start    (dfs),
        .s_frame_end      (dfe || interval_end),
        .s_restart        (interval_start),
        .m_symbols        (symbols),
        .m_amplitudes     (amplitudes),
        .m_sizes          (sizes),
        .m_dc             (flags),
        .m_count          (symbol_count),
        .m_chroma         (chroma),
        .m_frame_end      (efe),
        .m_valid          (e_valid),
        .m_ready          (e_ready),
        .coefficient_error(coefficient_error)
    );
    // Local input storage isolates coefficient processing from entropy stalls.
    wire [124:0] huff_input;
    wire huff_input_valid, huff_input_ready;
    jpeg_stream_buffer #(
        .WIDTH(125)
    ) huff_input_buffer (
        .clk    (clk),
        .rst_n  (rst_n),
        .s_data ({symbols, amplitudes, sizes, flags, symbol_count, chroma, efe}),
        .s_valid(e_valid),
        .s_ready(e_ready),
        .m_data (huff_input),
        .m_valid(huff_input_valid),
        .m_ready(huff_input_ready)
    );
    huffman_encoder huff (
        .clk         (clk),
        .rst_n       (rst_n),
        .s_symbols   (huff_input[124:85]),
        .s_amplitudes(huff_input[84:30]),
        .s_sizes     (huff_input[29:10]),
        .s_dc        (huff_input[9:5]),
        .s_count     (huff_input[4:2]),
        .s_chroma    (huff_input[1]),
        .s_frame_end (huff_input[0]),
        .s_valid     (huff_input_valid),
        .s_ready     (huff_input_ready),
        .m_bits      (bits),
        .m_length    (bit_length),
        .m_frame_end (ffe),
        .m_valid     (f_valid),
        .m_ready     (f_ready)
    );
    // Prevent the packer's space/ready logic from driving the Huffman pipeline.
    wire [136:0] packer_input;
    wire packer_input_valid, packer_input_ready;
    jpeg_stream_buffer #(
        .WIDTH(137)
    ) huff_output_buffer (
        .clk    (clk),
        .rst_n  (rst_n),
        .s_data ({bits, bit_length, ffe}),
        .s_valid(f_valid),
        .s_ready(f_ready),
        .m_data (packer_input),
        .m_valid(packer_input_valid),
        .m_ready(packer_input_ready)
    );
    entropy_packer packer (
        .clk        (clk),
        .rst_n      (rst_n),
        .s_bits     (packer_input[136:9]),
        .s_length   (packer_input[8:1]),
        .s_frame_end(packer_input[0]),
        .s_valid    (packer_input_valid),
        .s_ready    (packer_input_ready),
        .m_data     (entropy),
        .m_bytes    (entropy_bytes),
        .m_frame_end(gfe),
        .m_valid    (g_valid),
        .m_ready    (g_ready)
    );
    // Header/EOI state must not control the packer's CE and Huffman buffer
    // through a long combinational ready path. Keep bytes and EOF together.
    jpeg_stream_buffer #(
        .WIDTH(134)
    ) formatter_input_buffer (
        .clk    (clk),
        .rst_n  (rst_n),
        .s_data ({entropy, entropy_bytes, gfe}),
        .s_valid(g_valid),
        .s_ready(g_ready),
        .m_data (formatter_input),
        .m_valid(formatter_input_valid),
        .m_ready(formatter_input_ready)
    );
    jpeg_formatter #(.RESTART_MCUS(RESTART_MCUS)) format (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (formatter_start),
        .frame_width (width),
        .frame_height(height),
        .frame_gray  (gray),
        .q_read_addr (q_addr),
        .q_read_data (q_data),
        .s_data      (formatter_input[133:6]),
        .s_bytes     (formatter_input[5:1]),
        .s_frame_end (formatter_input[0]),
        .s_valid     (formatter_input_valid),
        .s_ready     (formatter_input_ready),
        .m_data      (m_data),
        .m_bytes     (m_bytes),
        .m_last      (m_last),
        .m_valid     (m_valid),
        .m_ready     (m_ready)
    );
endmodule
