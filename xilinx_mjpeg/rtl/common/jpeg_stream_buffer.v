// Two-entry elastic buffer. Upstream ready depends only on local occupancy.
// One beat/cycle is sustained while occupancy is one; a full-buffer recovery
// can pause upstream for one cycle. Payload includes all associated markers.
module jpeg_stream_buffer #(
    parameter WIDTH = 125
) (
    input clk,
    input rst_n,
    input [WIDTH-1:0] s_data,
    input s_valid,
    output s_ready,
    output [WIDTH-1:0] m_data,
    output m_valid,
    input m_ready
);
    (* preserve=1, max_fanout=16 *) reg [WIDTH-1:0] head;
    reg [WIDTH-1:0] tail;
    reg head_valid, tail_valid;
    assign s_ready = !tail_valid;
    assign m_data = head;
    assign m_valid = head_valid;
    wire push = s_valid && s_ready;
    wire pop = head_valid && m_ready;
    always @(posedge clk) begin
        if (pop && tail_valid) head <= tail;
        else if (push && (!head_valid || pop)) head <= s_data;
        if (push && head_valid && !pop) tail <= s_data;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_valid <= 0;
            tail_valid <= 0;
        end else
            case ({
                push, pop
            })
                2'b10:
                if (head_valid) tail_valid <= 1;
                else head_valid <= 1;
                2'b01:
                if (tail_valid) tail_valid <= 0;
                else head_valid <= 0;
                default: begin
                end
            endcase
    end
endmodule
