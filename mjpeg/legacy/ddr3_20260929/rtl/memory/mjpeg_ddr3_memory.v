// Board DDR3 PHY/controller plus a burst bridge to the encoder clock domain.
// The common reset also resets MIG: USB clock loss/reopen cannot leave a
// partially committed reference transaction alive in only one clock domain.
module mjpeg_ddr3_memory(
    input clk,rst_n,ref_clk_200m,
    input cmd_valid,cmd_write,input [27:0] cmd_addr,input [13:0] cmd_bytes,output cmd_ready,
    input [127:0] w_data,input [15:0] w_keep,input w_valid,w_last,output w_ready,
    output [127:0] r_data,output r_valid,r_last,input r_ready,
    output done,error,fatal,output ready,
    inout [15:0] ddr3_dq,inout [1:0] ddr3_dqs_n,ddr3_dqs_p,
    output [13:0] ddr3_addr,output [2:0] ddr3_ba,
    output ddr3_ras_n,ddr3_cas_n,ddr3_we_n,ddr3_reset_n,
    output [0:0] ddr3_ck_p,ddr3_ck_n,ddr3_cke,ddr3_cs_n,ddr3_odt,
    output [1:0] ddr3_dm
);
    wire ui_clk,ui_rst,calibrated;
    wire [27:0] app_addr;
    wire [2:0] app_cmd;
    wire app_en,app_rdy,app_wdf_wren,app_wdf_rdy,app_wdf_end;
    wire [127:0] app_wdf_data,app_rd_data;
    wire [15:0] app_wdf_mask;
    wire app_rd_data_valid,app_rd_data_end;
    ddr3_burst_bridge bridge(
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
        .cmd_write(cmd_write),.cmd_addr(cmd_addr),.cmd_bytes(cmd_bytes),
        .w_data(w_data),.w_keep(w_keep),.w_valid(w_valid),.w_ready(w_ready),.w_last(w_last),
        .r_data(r_data),.r_valid(r_valid),.r_ready(r_ready),.r_last(r_last),
        .done(done),.error(error),.fatal(fatal),.ready(ready),
        .ui_clk(ui_clk),.ui_rst(ui_rst),.init_calib_complete(calibrated),
        .app_addr(app_addr),.app_cmd(app_cmd),.app_en(app_en),.app_rdy(app_rdy),
        .app_wdf_data(app_wdf_data),.app_wdf_mask(app_wdf_mask),
        .app_wdf_wren(app_wdf_wren),.app_wdf_rdy(app_wdf_rdy),.app_wdf_end(app_wdf_end),
        .app_rd_data(app_rd_data),.app_rd_data_valid(app_rd_data_valid),.app_rd_data_end(app_rd_data_end));
    davinci_ddr3_mig controller(
        .ddr3_dq(ddr3_dq),.ddr3_dqs_n(ddr3_dqs_n),.ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_addr(ddr3_addr),.ddr3_ba(ddr3_ba),.ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n),.ddr3_we_n(ddr3_we_n),.ddr3_reset_n(ddr3_reset_n),
        .ddr3_ck_p(ddr3_ck_p),.ddr3_ck_n(ddr3_ck_n),.ddr3_cke(ddr3_cke),
        .ddr3_cs_n(ddr3_cs_n),.ddr3_dm(ddr3_dm),.ddr3_odt(ddr3_odt),
        .sys_clk_i(ref_clk_200m),.clk_ref_i(ref_clk_200m),.sys_rst(rst_n),
        .ui_clk(ui_clk),.ui_clk_sync_rst(ui_rst),.init_calib_complete(calibrated),
        .app_addr(app_addr),.app_cmd(app_cmd),.app_en(app_en),.app_rdy(app_rdy),
        .app_wdf_data(app_wdf_data),.app_wdf_mask(app_wdf_mask),
        .app_wdf_wren(app_wdf_wren),.app_wdf_rdy(app_wdf_rdy),.app_wdf_end(app_wdf_end),
        .app_rd_data(app_rd_data),.app_rd_data_valid(app_rd_data_valid),.app_rd_data_end(app_rd_data_end),
        .app_sr_req(1'b0),.app_ref_req(1'b0),.app_zq_req(1'b0),
        .app_sr_active(),.app_ref_ack(),.app_zq_ack(),.device_temp());
endmodule
