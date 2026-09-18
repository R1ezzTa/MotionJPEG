// One-second windows in the FPGA clock domain. Events on the last clock of
// a window belong to that window. Idle windows report zero, not a stale rate.
module frame_rate_meter #(parameter CLOCK_HZ=50000000)(
    input clk,rst_n,input input_frame,success_frame,failed_frame,
    output reg sample_valid,output reg [31:0] window_id,
    output reg [31:0] input_fps,compressed_fps,failed_fps,total_compressed
);
    reg [31:0] ticks,input_count,success_count,failed_count,total_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ticks<=0;input_count<=0;success_count<=0;failed_count<=0;total_count<=0;
            sample_valid<=0;window_id<=0;input_fps<=0;compressed_fps<=0;failed_fps<=0;total_compressed<=0;
        end else begin
            sample_valid<=0;
            if (success_frame) total_count<=total_count+1'b1;
            if (ticks==CLOCK_HZ-1) begin
                ticks<=0;input_count<=0;success_count<=0;failed_count<=0;
                sample_valid<=1;window_id<=window_id+1'b1;
                input_fps<=input_count+input_frame;
                compressed_fps<=success_count+success_frame;
                failed_fps<=failed_count+failed_frame;
                total_compressed<=total_count+success_frame;
            end else begin
                ticks<=ticks+1'b1;
                if (input_frame) input_count<=input_count+1'b1;
                if (success_frame) success_count<=success_count+1'b1;
                if (failed_frame) failed_count<=failed_count+1'b1;
            end
        end
    end
endmodule
