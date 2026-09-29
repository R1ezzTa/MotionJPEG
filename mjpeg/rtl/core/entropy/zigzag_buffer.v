module zigzag_buffer (
    input clk,
    input rst_n,
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
    `include "rtl/generated/zigzag.vh"
    (* ram_style="distributed" *) reg [15:0] even_mem[0:63],odd_mem[0:63];
    reg [3:0] meta[0:1];
    reg [1:0] full;
    reg wb, rb;
    reg [4:0] pair;
    // The natural input order always writes one even and one odd coefficient.
    // RAMs retain the original one-clock write delay without 128 FF write decoders.
    reg [31:0] write_data;
    reg write_valid, write_bank;
    reg [4:0] write_pair;
    reg [1:0] write_component;
    reg write_start, write_end;
    assign s_ready = !full[wb];
    wire ce = !m_valid || m_ready;
    always @(posedge clk) begin
        if(s_valid && s_ready) write_data<=s_data;
        if(write_valid) begin
            even_mem[{write_bank,write_pair}]<=write_data[15:0];
            odd_mem[{write_bank,write_pair}]<=write_data[31:16];
        end
    end
    wire [5:0] index0=zigzag({pair,1'b0}),index1=zigzag({pair,1'b1});
    wire [15:0] read0=index0[0]?odd_mem[{rb,index0[5:1]}]:even_mem[{rb,index0[5:1]}];
    wire [15:0] read1=index1[0]?odd_mem[{rb,index1[5:1]}]:even_mem[{rb,index1[5:1]}];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            full <= 0;
            wb <= 0;
            rb <= 0;
            pair <= 0;
            meta[0] <= 0;
            meta[1] <= 0;
            write_valid <= 0;
            write_bank <= 0;
            write_pair <= 0;
            write_component <= 0;
            write_start <= 0;
            write_end <= 0;
            m_data <= 0;
            m_valid <= 0;
            m_component <= 0;
            m_pair <= 0;
            m_frame_start <= 0;
            m_frame_end <= 0;
        end else begin
            write_valid <= s_valid && s_ready;
            if (s_valid && s_ready) begin
                write_bank <= wb;
                write_pair <= s_pair;
                write_component <= s_component;
                write_start <= s_frame_start;
                write_end <= s_frame_end;
                if (s_pair == 31) wb <= !wb;
            end
            if (write_valid) begin
                if (write_pair == 0) meta[write_bank] <= {write_component, write_start, 1'b0};
                if (write_pair == 31) begin
                    meta[write_bank][0] <= write_end;
                    full[write_bank] <= 1;
                end
            end
            if (ce) begin
                m_valid <= full[rb];
                if (full[rb]) begin
                    m_data <= {read1,read0};
                    m_component <= meta[rb][3:2];
                    m_pair <= pair;
                    m_frame_start <= meta[rb][1] && (pair == 0);
                    m_frame_end <= meta[rb][0] && (pair == 31);
                    if (pair == 31) begin
                        pair <= 0;
                        full[rb] <= 0;
                        rb <= !rb;
                    end else pair <= pair + 1'b1;
                end
            end
        end
    end
endmodule
