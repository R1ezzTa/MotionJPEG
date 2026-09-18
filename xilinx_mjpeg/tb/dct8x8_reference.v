// Two sample lanes; 25 compute clocks per block, overlapped with 32-clock I/O.
module dct8x8_reference (
    input clk,
    input rst_n,
    input [15:0] s_data,
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
    reg [2047:0] pixels, coeffs;
    reg [1023:0] workmat;
    reg [8:0] imeta[0:1], ometa[0:1];
    reg [1:0] ifull, ofull;
    reg iw, ir, ow, orr;
    reg [4:0] op;
    reg [2:0] state, index;
    reg job_ib, job_ob;
    reg [8:0] job_meta;
    localparam IDLE = 0, ROWS = 1, ROW_WAIT = 2, COLS = 3, COL_WAIT = 4;
    assign s_ready = !ifull[iw];
    wire output_ce = !m_valid || m_ready;
    reg [127:0] vec;
    integer n;
    always @* begin
        vec = 0;
        for (n = 0; n < 8; n = n + 1) begin
            if (state == ROWS) vec[n*16+:16] = pixels[(job_ib*64+index*8+n)*16+:16];
            else vec[n*16+:16] = workmat[(n*8+index)*16+:16];
        end
    end
    wire result_valid;
    wire [255:0] results;
    wire [3:0] result_tag;
    dct1d engine (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid       (state == ROWS || state == COLS),
        .samples     (vec),
        .tag         ({state == COLS, index}),
        .result_valid(result_valid),
        .results     (results),
        .result_tag  (result_tag)
    );
    function signed [15:0] rounded;
        input signed [31:0] value;
        input column;
        reg signed [32:0] wide;
        begin
            // Arithmetic right shift rounds down. For negative values, half-1
            // gives nearest rounding with ties away from zero using one adder.
            if (column) wide = $signed(value) + (value < 0 ? 33'sd32767 : 33'sd32768);
            else wide = $signed(value) + (value < 0 ? 33'sd127 : 33'sd128);
            rounded = column ? wide >>> 16 : wide >>> 8;
        end
    endfunction
    genvar g;
    generate
        for (g = 0; g < 128; g = g + 1) begin : storage
            always @(posedge clk) begin
                if (s_valid && s_ready && (iw == g / 64) && (s_pair == (g % 64) / 2))
                    pixels[g*16+:16] <= $signed({1'b0, s_data[(g%2)*8+:8]}) - 16'sd128;
                if (result_valid && result_tag[3] && (job_ob == g / 64) &&
                    (result_tag[2:0] == g % 8))
                    coeffs[g*16+:16] <= rounded($signed(results[((g%64)/8)*32+:32]), 1);
            end
        end
        for (g = 0; g < 64; g = g + 1) begin : transpose_storage
            always @(posedge clk)
                if (result_valid && !result_tag[3] && (result_tag[2:0] == g / 8))
                    workmat[g*16+:16] <= rounded($signed(results[(g%8)*32+:32]), 0);
        end
    endgenerate
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ifull <= 0;
            ofull <= 0;
            iw <= 0;
            ir <= 0;
            ow <= 0;
            orr <= 0;
            op <= 0;
            state <= IDLE;
            index <= 0;
            job_ib <= 0;
            job_ob <= 0;
            job_meta <= 0;
            imeta[0] <= 0;
            imeta[1] <= 0;
            ometa[0] <= 0;
            ometa[1] <= 0;
            m_data <= 0;
            m_valid <= 0;
            m_component <= 0;
            m_pair <= 0;
            m_frame_start <= 0;
            m_frame_end <= 0;
        end else begin
            if (s_valid && s_ready) begin
                if (s_pair == 0) imeta[iw] <= {s_component, 5'd0, s_frame_start, 1'b0};
                if (s_pair == 31) begin
                    imeta[iw][0] <= s_frame_end;
                    ifull[iw] <= 1;
                    iw <= !iw;
                end
            end
            if (output_ce) begin
                m_valid <= ofull[orr];
                if (ofull[orr]) begin
                    m_data <= coeffs[(orr*64+op*2)*16+:32];
                    m_component <= ometa[orr][8:7];
                    m_pair <= op;
                    m_frame_start <= ometa[orr][1] && (op == 0);
                    m_frame_end <= ometa[orr][0] && (op == 31);
                    if (op == 31) begin
                        ofull[orr] <= 0;
                        orr <= !orr;
                        op <= 0;
                    end else op <= op + 1'b1;
                end
            end
            case (state)
                IDLE:
                if (ifull[ir] && !ofull[ow]) begin
                    job_ib <= ir;
                    job_ob <= ow;
                    job_meta <= imeta[ir];
                    index <= 0;
                    state <= ROWS;
                end
                ROWS:
                if (index == 7) begin
                    state <= ROW_WAIT;
                    ifull[job_ib] <= 0;
                    ir <= !ir;
                end else index <= index + 1'b1;
                COLS:
                if (index == 7) state <= COL_WAIT;
                else index <= index + 1'b1;
                default: begin
                end
            endcase
            if (result_valid) begin
                if (!result_tag[3]) begin
                    if (result_tag[2:0] == 7) begin
                        index <= 0;
                        state <= COLS;
                    end
                end else begin
                    if (result_tag[2:0] == 7) begin
                        ofull[job_ob] <= 1;
                        ometa[job_ob] <= job_meta;
                        ow <= !ow;
                        state <= IDLE;
                    end
                end
            end
        end
    end
endmodule
