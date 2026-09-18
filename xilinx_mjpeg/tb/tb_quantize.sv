`timescale 1ns / 1ps
// Exact division check for every q=1..255 and coefficients -2048..2047.
module tb_quantize;
    reg clk = 0;
    always #2.5 clk = ~clk;
    reg rst_n = 0;
    reg cfg_valid = 0, busy = 0;
    wire cfg_ready, tables_ready, config_error;
    reg [6:0] cfg_addr;
    reg [7:0] cfg_value;
    reg [20:0] cfg_recip;
    reg [6:0] q_read_addr = 0;
    wire [7:0] q_read_data;
    reg [31:0] s_data;
    reg s_valid = 0;
    wire s_ready;
    reg [1:0] s_component = 0;
    reg [4:0] s_pair = 0;
    reg s_frame_start = 0, s_frame_end = 0;
    wire [31:0] m_data;
    wire m_valid;
    reg m_ready = 1;
    wire [1:0] m_component;
    wire [4:0] m_pair;
    wire m_frame_start, m_frame_end;
    quantize dut (.*);
    integer q, k, c, received = 0, expected_value, reference[0:4095], output_index = 0, marker;
    always @(posedge clk)
        if (rst_n && m_valid && m_ready) begin
            if ($signed(
                    m_data[15:0]
                ) !== reference[output_index] || $signed(
                    m_data[31:16]
                ) !== reference[output_index+1])
                $fatal(
                    1,
                    "q=%0d coefficient index=%0d result=%0d",
                    q,
                    output_index,
                    $signed(
                        m_data[15:0]
                    )
                );
            output_index = output_index + 2;
            received = received + 2;
        end
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        for (q = 1; q <= 255; q = q + 1) begin
            for (k = 0; k < 128; k = k + 1) begin
                @(negedge clk);
                cfg_valid = 1;
                cfg_addr = k;
                cfg_value = q;
                cfg_recip = (1048576 + q - 1) / q;
            end
            @(negedge clk);
            cfg_valid = 0;
            output_index = 0;
            for (k = 0; k < 4096; k = k + 1) begin
                c = k - 2048;
                expected_value = ((c < 0 ? -c : c) + (q / 2)) / q;
                reference[k] = c < 0 ? -expected_value : expected_value;
            end
            for (k = 0; k < 4096; k = k + 2) begin
                @(negedge clk);
                s_valid = 1;
                s_data[15:0] = k - 2048;
                s_data[31:16] = k - 2047;
                s_pair = (k / 2) % 32;
                s_component = (k / 64) % 3;
                @(posedge clk);
                while (!s_ready) @(posedge clk);
            end
            @(negedge clk);
            s_valid = 0;
            wait (output_index == 4096);
            @(negedge clk);
        end
        @(negedge clk);
        cfg_valid = 1;
        cfg_addr = 0;
        cfg_value = 0;
        cfg_recip = 1048576;
        @(negedge clk);
        cfg_valid = 0;
        if (!config_error || q_read_data != 255) $fatal(1, "Invalid q write was not rejected");
        marker = $fopen("QUANT_PASS.txt", "w");
        $fwrite(
            marker,
            "1044480 coefficients checked against integer division; invalid zero q rejected.\n");
        $fclose(marker);
        $display("QUANT_EXHAUSTIVE_PASS coefficients=%0d", received);
        $finish;
    end
endmodule
