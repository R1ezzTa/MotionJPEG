// Atomic, latest-pending snapshot mailbox. The bus remains unchanged until
// the receiver acknowledges it; only request/acknowledge toggles synchronize.
module board_test_cdc_snapshot #(parameter WIDTH=224)(
    input s_clk,s_rst_n,input s_valid,input [WIDTH-1:0] s_data,
    input m_clk,m_rst_n,output reg m_valid,output reg [WIDTH-1:0] m_data
);
    reg [WIDTH-1:0] held_data,pending_data;
    reg request,acknowledge,pending;
    (* ASYNC_REG="TRUE" *) reg ack_s1,ack_s2,request_m1,request_m2;
    always @(posedge s_clk or negedge s_rst_n) begin
        if(!s_rst_n) begin
            held_data<=0;pending_data<=0;pending<=0;request<=0;ack_s1<=0;ack_s2<=0;
        end else begin
            ack_s1<=acknowledge;ack_s2<=ack_s1;
            if(request==ack_s2 && pending) begin
                held_data<=pending_data;request<=!request;pending<=0;
            end
            if(s_valid) begin pending_data<=s_data;pending<=1;end
        end
    end
    always @(posedge m_clk or negedge m_rst_n) begin
        if(!m_rst_n) begin m_valid<=0;m_data<=0;acknowledge<=0;request_m1<=0;request_m2<=0;end
        else begin
            request_m1<=request;request_m2<=request_m1;m_valid<=0;
            if(request_m2!=acknowledge) begin
                m_data<=held_data;m_valid<=1;acknowledge<=request_m2;
            end
        end
    end
endmodule
