// Standalone DDR3 acceptance image. No camera/JPEG logic is instantiated.
module davinci_ddr3_selftest_top(
    input sys_clk,sys_rst_n,usb_clk_60m,
    inout [7:0] usb_data,input usb_rxf_n,usb_txe_n,
    output usb_rd_n,usb_wr_n,usb_oe_n,usb_siwu_n,output [3:0] led,
    inout [15:0] ddr3_dq,inout [1:0] ddr3_dqs_n,ddr3_dqs_p,
    output [13:0] ddr3_addr,output [2:0] ddr3_ba,
    output ddr3_ras_n,ddr3_cas_n,ddr3_we_n,ddr3_reset_n,
    output [0:0] ddr3_ck_p,ddr3_ck_n,ddr3_cke,ddr3_cs_n,ddr3_odt,
    output [1:0] ddr3_dm
);
    wire clk,ref_clk_200m,locked,usb_clk,run_rst_n;
    board_test_core_clock clocks(.ref_clk(sys_clk),.rst_n(sys_rst_n),
        .core_clk(clk),.locked(locked),.ddr_ref_clk(ref_clk_200m));
    BUFG usb_clock_buffer(.I(usb_clk_60m),.O(usb_clk));
    board_test_usb_clock_guard #(.TIMEOUT_CYCLES(100000)) clock_guard(
        .sys_clk(clk),.usb_clk(usb_clk),.sys_rst_n(locked),.run_rst_n(run_rst_n));
    (* ASYNC_REG="TRUE" *) reg [2:0] reset_pipe=0,usb_reset_pipe=0;
    always @(posedge clk or negedge run_rst_n)
        if(!run_rst_n) reset_pipe<=0;else reset_pipe<={reset_pipe[1:0],1'b1};
    always @(posedge usb_clk or negedge run_rst_n)
        if(!run_rst_n) usb_reset_pipe<=0;else usb_reset_pipe<={usb_reset_pipe[1:0],1'b1};
    wire rst_n=reset_pipe[2];
    wire [7:0] tx_data,usb_tx_data;
    wire tx_valid,tx_ready,usb_tx_valid,usb_tx_ready;
    board_test_async_fifo #(.ADDRESS_BITS(9)) tx_fifo(
        .wclk(clk),.wrst_n(rst_n),.s_data(tx_data),.s_valid(tx_valid),.s_ready(tx_ready),
        .rclk(usb_clk),.rrst_n(usb_reset_pipe[2]),.m_data(usb_tx_data),.m_valid(usb_tx_valid),.m_ready(usb_tx_ready));
    board_test_ft245_sync link(
        .clk(usb_clk),.rst_n(usb_reset_pipe[2]),.usb_data(usb_data),
        .usb_rxf_n(usb_rxf_n),.usb_txe_n(usb_txe_n),.usb_rd_n(usb_rd_n),
        .usb_wr_n(usb_wr_n),.usb_oe_n(usb_oe_n),.usb_siwu_n(usb_siwu_n),
        .rx_data(),.rx_valid(),.rx_ready(1'b1),.tx_data(usb_tx_data),.tx_valid(usb_tx_valid),
        .tx_ready(usb_tx_ready),.stats_valid(),.stats_data());
    wire cmd_valid,cmd_ready,cmd_write,w_valid,w_ready,w_last,r_valid,r_ready,r_last,done,error,fatal,ready;
    wire [27:0] cmd_addr;
    wire [13:0] cmd_bytes;
    wire [127:0] w_data,r_data;
    wire [15:0] w_keep;
    ddr3_selftest_core tester(
        .clk(clk),.rst_n(rst_n),.ready(ready),.fatal(fatal),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_bytes(cmd_bytes),
        .w_data(w_data),.w_keep(w_keep),.w_valid(w_valid),.w_ready(w_ready),.w_last(w_last),
        .r_data(r_data),.r_valid(r_valid),.r_ready(r_ready),.r_last(r_last),.done(done),.error(error),
        .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.led(led));
    mjpeg_ddr3_memory memory(
        .clk(clk),.rst_n(run_rst_n),.ref_clk_200m(ref_clk_200m),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_bytes(cmd_bytes),
        .w_data(w_data),.w_keep(w_keep),.w_valid(w_valid),.w_ready(w_ready),.w_last(w_last),
        .r_data(r_data),.r_valid(r_valid),.r_ready(r_ready),.r_last(r_last),.done(done),.error(error),.fatal(fatal),.ready(ready),
        .ddr3_dq(ddr3_dq),.ddr3_dqs_n(ddr3_dqs_n),.ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_addr(ddr3_addr),.ddr3_ba(ddr3_ba),.ddr3_ras_n(ddr3_ras_n),.ddr3_cas_n(ddr3_cas_n),
        .ddr3_we_n(ddr3_we_n),.ddr3_reset_n(ddr3_reset_n),.ddr3_ck_p(ddr3_ck_p),.ddr3_ck_n(ddr3_ck_n),
        .ddr3_cke(ddr3_cke),.ddr3_cs_n(ddr3_cs_n),.ddr3_dm(ddr3_dm),.ddr3_odt(ddr3_odt));
endmodule
