// Beat-wise round robin, followed by two-entry registered storage. A JPEG
// frame may interleave with other channels; its tag travels with every beat.
module mjpeg_arbiter #(
    parameter CHANNELS = 2,
    WIDTH = 167
) (
    input clk,
    input rst_n,
    input [CHANNELS*WIDTH-1:0] s_data,
    input [CHANNELS-1:0] s_valid,
    output reg [CHANNELS-1:0] s_ready,
    output [WIDTH+1:0] m_data,
    output m_valid,
    input m_ready
);
    (* max_fanout=16 *) reg [1:0] next_channel;
    reg found;
    reg [1:0] selected;
    integer offset, index;
    wire buffer_ready;
    always @* begin
        found = 0;
        selected = 0;
        s_ready = 0;
        index = 0;
        for (offset = 0; offset < CHANNELS; offset = offset + 1) begin
            index = next_channel + offset;
            if (index >= CHANNELS) index = index - CHANNELS;
            if (!found && s_valid[index]) begin
                found = 1;
                selected = index;
            end
        end
        if (found) s_ready[selected] = buffer_ready;
    end
    jpeg_stream_buffer #(
        .WIDTH(WIDTH + 2)
    ) output_buffer (
        .clk    (clk),
        .rst_n  (rst_n),
        .s_data ({selected, s_data[selected*WIDTH+:WIDTH]}),
        .s_valid(found),
        .s_ready(buffer_ready),
        .m_data (m_data),
        .m_valid(m_valid),
        .m_ready(m_ready)
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) next_channel <= 0;
        else if (found && buffer_ready)
            next_channel <= selected == CHANNELS - 1 ? 2'd0 : selected + 1'b1;
    end
endmodule
