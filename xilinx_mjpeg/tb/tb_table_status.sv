`timescale 1ns / 1ps
// Readiness must describe distinct valid entries, including reset and replay.
module tb_table_status;
    reg clk = 0;
    always #2.5 clk = ~clk;
    reg rst_n = 0;
    reg cfg_valid = 0, busy = 0;
    wire cfg_ready, tables_ready, config_error;
    reg [6:0] cfg_addr = 0;
    reg [7:0] cfg_value = 8'd17;
    reg [20:0] cfg_recip = 21'd61681;
    reg [6:0] q_read_addr = 0;
    wire [7:0] q_read_data;
    reg [31:0] s_data = 0;
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
    integer k, marker;

    task write_entry(input integer address, input integer value, reciprocal);
        begin
            @(negedge clk);
            cfg_valid = 1;
            cfg_addr = address;
            cfg_value = value;
            cfg_recip = reciprocal;
            @(negedge clk);
            cfg_valid = 0;
        end
    endtask

    task finish_table;
        begin
            write_entry(37, 17, 61681);
            if (tables_ready) $fatal(1, "Readiness bypassed the status registers");
            @(negedge clk);
            if (tables_ready) $fatal(1, "Readiness asserted one clock too early");
            @(negedge clk);
            if (!tables_ready) $fatal(1, "Readiness did not arrive after two clocks");
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        // Odd multiplier permutes all 128 addresses; leave entry 37 missing.
        for (k = 0; k < 128; k = k + 1)
        if (((k * 53) % 128) != 37) write_entry((k * 53) % 128, 17, 61681);
        repeat (12) write_entry(0, 17, 61681);
        repeat (4) @(negedge clk);
        if (tables_ready) $fatal(1, "Duplicate writes hid a missing table entry");

        busy = 1;
        write_entry(37, 17, 61681);
        repeat (4) @(negedge clk);
        if (cfg_ready || tables_ready) $fatal(1, "Busy configuration was accepted");
        busy = 0;
        write_entry(37, 0, 61681);
        write_entry(37, 17, 0);
        repeat (4) @(negedge clk);
        if (tables_ready || !config_error) $fatal(1, "Invalid entry completed a table");
        finish_table();
        write_entry(11, 31, 33826);
        if (!tables_ready) $fatal(1, "Updating a complete table cleared readiness");

        // Clear all three status stages while configuration is incomplete.
        #1 rst_n = 0;
        #0.1;
        if (tables_ready) $fatal(1, "Reset did not clear readiness immediately");
        repeat (3) @(negedge clk);
        rst_n = 1;
        repeat (4) @(negedge clk);
        if (tables_ready || config_error) $fatal(1, "Stale state survived reset");
        for (k = 127; k >= 0; k = k - 1) if (k != 37) write_entry(k, 17, 61681);
        finish_table();
        marker = $fopen("TABLE_PASS.txt", "w");
        $fwrite(
            marker,
            "Distinct entries, duplicate/invalid/busy writes, two-clock status and reset replay passed.\n"
                );
        $fclose(marker);
        $display("TABLE_STATUS_PASS");
        $finish;
    end
    initial begin
        #30000;
        $fatal(1, "Table status timeout");
    end
endmodule
