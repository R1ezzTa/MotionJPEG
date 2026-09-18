`timescale 1ns / 1ps
`include "tb/dct8x8_reference.v"
// Compare ordered results against the previous DCT with independent stalls.
module tb_dct_input;
    localparam WORDS = 128 * 32;
    reg clk = 0;
    always #2.5 clk = ~clk;
    reg rst_n = 0;
    reg [1:0] epoch = 0;
    reg [15:0] data[0:1];
    reg valid[0:1];
    wire ready[0:1];
    reg [1:0] component[0:1];
    reg [4:0] pair[0:1];
    reg first[0:1], last[0:1];
    wire [31:0] result[0:1];
    wire result_valid[0:1];
    reg result_ready[0:1];
    wire [1:0] result_component[0:1];
    wire [4:0] result_pair[0:1];
    wire result_first[0:1], result_last[0:1];
    integer sent[0:1], received[0:1];
    reg took[0:1];
    reg [40:0] outputs[0:1][0:WORDS-1];
    reg [31:0] random_state = 32'h2468ac13;
    integer lane, checked = 0, ticks = 0, marker;

    dct8x8_reference reference_dct (
        .clk          (clk),
        .rst_n        (rst_n),
        .s_data       (data[0]),
        .s_valid      (valid[0]),
        .s_ready      (ready[0]),
        .s_component  (component[0]),
        .s_pair       (pair[0]),
        .s_frame_start(first[0]),
        .s_frame_end  (last[0]),
        .m_data       (result[0]),
        .m_valid      (result_valid[0]),
        .m_ready      (result_ready[0]),
        .m_component  (result_component[0]),
        .m_pair       (result_pair[0]),
        .m_frame_start(result_first[0]),
        .m_frame_end  (result_last[0])
    );
    dct8x8 candidate_dct (
        .clk          (clk),
        .rst_n        (rst_n),
        .s_data       (data[1]),
        .s_valid      (valid[1]),
        .s_ready      (ready[1]),
        .s_component  (component[1]),
        .s_pair       (pair[1]),
        .s_frame_start(first[1]),
        .s_frame_end  (last[1]),
        .m_data       (result[1]),
        .m_valid      (result_valid[1]),
        .m_ready      (result_ready[1]),
        .m_component  (result_component[1]),
        .m_pair       (result_pair[1]),
        .m_frame_start(result_first[1]),
        .m_frame_end  (result_last[1])
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            checked = 0;
            for (lane = 0; lane < 2; lane = lane + 1) begin
                sent[lane] = 0;
                received[lane] = 0;
                took[lane] = 0;
            end
        end else begin
            for (lane = 0; lane < 2; lane = lane + 1) begin
                took[lane] = valid[lane] && ready[lane];
                if (took[lane]) sent[lane] = sent[lane] + 1;
                if (result_valid[lane] && result_ready[lane]) begin
                    if (received[lane] >= WORDS) $fatal(1, "Extra DCT output");
                    outputs[lane][received[lane]] = {
                        result[lane],
                        result_component[lane],
                        result_pair[lane],
                        result_first[lane],
                        result_last[lane]
                    };
                    received[lane] = received[lane] + 1;
                end
            end
            while (checked < received[0] && checked < received[1]) begin
                if (outputs[0][checked] !== outputs[1][checked])
                    $fatal(1, "DCT result or metadata mismatch at pair %0d", checked);
                checked = checked + 1;
            end
        end
    end

    // Independent input gaps and long output stalls exercise both full banks.
    always @(negedge clk) begin
        random_state = {
            random_state[30:0],
            random_state[31] ^ random_state[21] ^ random_state[1] ^ random_state[0]
        };
        ticks = ticks + 1;
        for (integer j = 0; j < 2; j = j + 1) begin
            if (!rst_n) begin
                valid[j] = 0;
                result_ready[j] = 0;
            end else begin
                if (!valid[j] || took[j]) begin
                    valid[j] = sent[j] < WORDS && random_state[j*4+:3] != 0;
                    data[j] = {
                        8'((sent[j] * 71 + epoch * 113) ^ (sent[j] >> 2)),
                        8'((sent[j] * 29 + epoch * 47) ^ (sent[j] >> 3))
                    };
                    pair[j] = sent[j] % 32;
                    component[j] = (sent[j] / 32) % 3;
                    first[j] = (sent[j] % (32 * 3) == 0);
                    last[j] = (sent[j] % (32 * 3) == 95);
                end
                result_ready[j] = ticks % 257 >= 80 && random_state[j*4+8+:3] != 0;
            end
        end
    end

    initial begin
        for (integer j = 0; j < 2; j = j + 1) begin
            valid[j] = 0;
            result_ready[j] = 0;
            sent[j] = 0;
            received[j] = 0;
            took[j] = 0;
        end
        repeat (4) @(negedge clk);
        #0.1 rst_n = 1;
        wait (sent[1] == 32);
        // Abort between acceptance of pair 31 and its delayed storage write.
        #1 rst_n = 0;
        epoch = 1;
        repeat (4) @(negedge clk);
        #0.1 rst_n = 1;
        wait (candidate_dct.selected_valid);
        // Abort with a selected vector waiting at the DSP input.
        #1 rst_n = 0;
        epoch = 2;
        repeat (4) @(negedge clk);
        #0.1 rst_n = 1;
        wait (checked == WORDS);
        repeat (8) @(negedge clk);
        marker = $fopen("DCT_INPUT_PASS.txt", "w");
        $fwrite(
            marker,
            "128 blocks compared to previous DCT; independent gaps, long stalls, reset with final pair and selected vector pending.\n"
                );
        $fclose(marker);
        $display("DCT_INPUT_PASS pairs=%0d", checked);
        $finish;
    end
    initial begin
        #300000;
        $fatal(1, "DCT input timeout sent=%0d/%0d received=%0d/%0d", sent[0], sent[1], received[0],
               received[1]);
    end
endmodule
