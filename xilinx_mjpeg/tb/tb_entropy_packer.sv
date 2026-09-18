`timescale 1ns / 1ps
module tb_entropy_packer;
    reg clk = 0;
    always #2.5 clk = ~clk;
    reg rst_n = 0, s_valid = 0, s_frame_end = 0, m_ready = 0;
    reg [127:0] s_bits = 0;
    reg [7:0] s_length = 0;
    wire s_ready, m_valid, m_frame_end;
    wire [127:0] m_data;
    wire [4:0] m_bytes;
    entropy_packer dut (.*);
    reg [136:0] groups[0:2999];
    reg [7:0] expected[0:39999];
    reg [31:0] sizes[0:31];
    integer ng, nb, nf, fd, code, i, j, seen = 0, frames = 0, frame_bytes = 0, cycles = 0;
    reg [31:0] rng = 32'h20260916;
    reg held = 0, held_end;
    reg [127:0] held_data;
    reg [4:0] held_bytes;
    always @(negedge clk) begin
        rng = {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
        m_ready = rst_n && (rng[2:0] != 0) && !(cycles % 500 >= 200 && cycles % 500 < 300);
    end
    always @(posedge clk) begin
        cycles = cycles + 1;
        if (cycles > 100000) $fatal(1, "PACKER_WATCHDOG");
        if (rst_n) begin
            if (held && (!m_valid || m_data !== held_data || m_bytes !== held_bytes ||
                         m_frame_end !== held_end))
                $fatal(1, "PACKER_STALL_CHANGED");
            held = m_valid && !m_ready;
            held_data = m_data;
            held_bytes = m_bytes;
            held_end = m_frame_end;
            if (m_valid && m_ready) begin
                if (m_bytes > 16) $fatal(1, "PACKER_BYTE_COUNT");
                for (j = 0; j < m_bytes; j = j + 1) begin
                    if (seen >= nb || m_data[j*8+:8] !== expected[seen])
                        $fatal(1, "PACKER_BYTE_MISMATCH %0d", seen);
                    seen = seen + 1;
                    frame_bytes = frame_bytes + 1;
                end
                if (m_frame_end) begin
                    if (frames >= nf || frame_bytes != sizes[frames])
                        $fatal(1, "PACKER_FRAME_SIZE");
                    frames = frames + 1;
                    frame_bytes = 0;
                end
            end
        end else held = 0;
    end
    initial begin
        $readmemh("data/packer/groups.mem", groups);
        $readmemh("data/packer/expected.mem", expected);
        $readmemh("data/packer/sizes.mem", sizes);
        fd = $fopen("data/packer/counts.txt", "r");
        code = $fscanf(fd, "%d %d %d", ng, nb, nf);
        $fclose(fd);
        if (code != 3) $fatal(1, "PACKER_FIXTURES");
        repeat (6) @(negedge clk);
        rst_n = 1;
        for (i = 0; i < ng; i = i + 1) begin
            @(negedge clk);
            {s_frame_end, s_length, s_bits} = groups[i];
            s_valid = 1;
            do @(posedge clk); while (!s_ready);
        end
        @(negedge clk);
        s_valid = 0;
        wait (frames == nf);
        if (seen != nb) $fatal(1, "PACKER_FINAL_BYTES");
        fd = $fopen("SIM_PASS.txt", "w");
        $fdisplay(fd, "PACKER_BOUNDARY_PASS");
        $fclose(fd);
        $display("PACKER_BOUNDARY_PASS groups=%0d frames=%0d bytes=%0d", ng, nf, nb);
        $finish;
    end
endmodule
