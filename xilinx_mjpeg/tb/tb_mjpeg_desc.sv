`timescale 1ns / 1ps
module tb_mjpeg_desc;
    reg clk = 0;
    always #2.5 clk = ~clk;
    reg rst_n = 0;
    reg enable = 1, cfg_gray = 1;
    reg [15:0] cfg_width = 16, cfg_height = 16;
    reg cfg_q_valid = 0;
    wire cfg_q_ready;
    reg [6:0] cfg_q_addr = 0;
    reg [7:0] cfg_q_value = 0;
    reg [20:0] cfg_q_recip = 0;
    wire tables_ready, config_error, busy;
    reg [15:0] s_data = 0;
    reg s_valid = 0, s_sof = 0, s_eol = 0, s_eof = 0, s_abort = 0;
    wire s_ready;
    reg [63:0] s_timestamp = 0;
    wire [127:0] m_data;
    wire [4:0] m_bytes;
    wire m_first, m_last, m_valid;
    reg m_ready = 1;
    wire [1:0] m_channel, desc_channel;
    wire [31:0] m_frame_id, desc_frame_id, desc_length;
    wire [63:0] desc_timestamp;
    wire [15:0] desc_width, desc_height;
    wire desc_gray;
    wire [7:0] desc_status;
    wire desc_valid;
    reg desc_ready = 0;
    mjpeg_encoder #(.CHANNELS(1)) dut (.*);
    reg [15:0] pixels[0:255];
    reg [7:0] expected[0:621];
    reg [28:0] quant[0:127];
    integer
        cycles = 0,
        seen = 0,
        ended = 0,
        described = 0,
        f,
        j,
        p,
        out_file = 0,
        report_file,
        start_cycle[0:3];
    reg held = 0;
    reg [170:0] held_desc;
    wire [170:0] descriptor = {
        desc_channel,
        desc_frame_id,
        desc_timestamp,
        desc_length,
        desc_width,
        desc_height,
        desc_gray,
        desc_status
    };
    always @(posedge clk) begin
        cycles = cycles + 1;
        if (cycles > 100000) $fatal(1, "Descriptor watchdog");
        if (rst_n) begin
            if (held && (!desc_valid || descriptor !== held_desc))
                $fatal(1, "Descriptor changed under backpressure");
            held = desc_valid && !desc_ready;
            held_desc = descriptor;
            if (m_valid && m_ready) begin
                if (m_channel != 0 || m_frame_id != ended || m_first !== (seen == 0))
                    $fatal(1, "Buffered payload tags");
                if (seen == 0)
                    out_file = $fopen($sformatf("gray_ramp_ch0_f%0d_rtl.jpg", ended), "wb");
                for (j = 0; j < m_bytes; j = j + 1) begin
                    if (seen >= 622 || m_data[j*8+:8] !== expected[seen])
                        $fatal(1, "Queued frame byte mismatch");
                    $fwrite(out_file, "%c", m_data[j*8+:8]);
                    seen = seen + 1;
                end
                if (m_last) begin
                    if (seen != 622) $fatal(1, "Queued frame length");
                    $fclose(out_file);
                    out_file = 0;
                    seen = 0;
                    ended = ended + 1;
                end
            end
            if (desc_valid && desc_ready) begin
                if (desc_channel != 0 || desc_frame_id != described || described >= ended ||
                    desc_length != 622 || desc_width != 16 || desc_height != 16 || !desc_gray ||
                    desc_status != 0 || desc_timestamp !== 64'hfedc123400000000 + described)
                    $fatal(1, "Stored descriptor corrupted");
                $fwrite(report_file, "gray_ramp,0,%0d,16,16,622,%0d,0\n", described,
                        cycles - start_cycle[described]);
                described = described + 1;
            end
        end
    end
    task automatic send(input integer id);
        integer k;
        begin
            wait (!busy);
            start_cycle[id] = cycles;
            for (k = 0; k < 256; k = k + 1) begin
                @(negedge clk);
                s_valid = 1;
                s_data = pixels[k];
                s_sof = k == 0;
                s_eol = k % 16 == 15;
                s_eof = k == 255;
                s_timestamp = 64'hfedc123400000000 + id;
                @(posedge clk);
                while (!s_ready) @(posedge clk);
            end
            @(negedge clk);
            s_valid = 0;
            s_sof = 0;
            s_eol = 0;
            s_eof = 0;
        end
    endtask
    initial begin
        $readmemh("data/gray_ramp/pixels.mem", pixels);
        $readmemh("data/gray_ramp/expected.mem", expected);
        $readmemh("data/gray_ramp/quant.mem", quant);
        report_file = $fopen("mjpeg_results.csv", "w");
        $fwrite(report_file, "case,channel,frame_id,width,height,bytes,cycles,status\n");
        repeat (5) @(negedge clk);
        rst_n = 1;
        for (f = 0; f < 128; f = f + 1) begin
            @(negedge clk);
            cfg_q_valid = 1;
            cfg_q_addr = f;
            cfg_q_value = quant[f][7:0];
            cfg_q_recip = quant[f][28:8];
            @(posedge clk);
            if (!cfg_q_ready) $fatal(1, "Descriptor test table handshake");
        end
        @(negedge clk);
        cfg_q_valid = 0;
        send(0);
        send(1);
        send(2);
        wait (ended == 3);
        repeat (100) @(negedge clk);
        if (!busy || s_ready || described != 0)
            $fatal(1, "Full descriptor storage must stall admission");
        desc_ready = 1;
        wait (described == 3);
        send(3);
        wait (described == 4);
        repeat (10) @(negedge clk);
        if (busy || m_valid || desc_valid || config_error) $fatal(1, "Descriptor drain");
        $fclose(report_file);
        report_file = $fopen("SIM_PASS.txt", "w");
        $fwrite(
            report_file,
            "Three frames queued with descriptor ready low; stored payload tags and descriptors survive later frames. Fourth frame succeeds after drain. CHANNELS=1 verified.\n"
                );
        $fclose(report_file);
        $display("MJPEG_DESCRIPTOR_QUEUE_PASS");
        $finish;
    end
endmodule
