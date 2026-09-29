# Implementation-only CDC constraints: require mapped synchronizer registers.
set_false_path -from [get_ports {key[*]}] \
    -to [get_pins -hier -filter {NAME =~ *controls/key_meta_reg*/D}]
# Do not false-path clock groups: Gray bus transit and skew remain bounded.
# Camera PCLK is on the vendor's non-clock-capable F14 pin. Apply after
# synthesis, when the IBUF output net exists, rather than before IO insertion.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_pins cam_pclk_IBUF_inst/O]]
# The vendor non-CCIO clock route is late. Forced HR ILOGIC registers add a
# fixed ZHOLD delay (~5.7 ns) unnecessarily on this falling-launch interface.
# Fabric input registers avoid ILOGIC's large fixed delay. High-rate clocks
# are deskewed by an MMCM; the capture edge precedes the next sensor launch.
set_property IOB FALSE [get_ports {cam_data[*] cam_href cam_vsync}]
set_property IOB FALSE [get_cells -hier -filter {IS_SEQUENTIAL == 1 && (NAME =~ *pin_data_reg* || NAME =~ *pin_vsync_reg* || NAME =~ *pin_href_reg*)}]
# All camera I/O paths use ordinary single-cycle setup and hold. At 75MHz,
# -30deg falling capture samples the previous byte before the new launch.
set_clock_uncertainty 0.250 -from [get_clocks cam_clk] -to [get_clocks -include_generated_clocks cam_clk]
set_max_delay -datapath_only 10.000 \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && (NAME =~ *tx_fifo/wgray_reg* || NAME =~ *tx_fifo/wbin_reg*)}] \
    -to [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *tx_fifo/wgray_r1_reg*}]
set_bus_skew 10.000 \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && (NAME =~ *tx_fifo/wgray_reg* || NAME =~ *tx_fifo/wbin_reg*)}] \
    -to [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *tx_fifo/wgray_r1_reg*}]
set_max_delay -datapath_only 16.667 \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && (NAME =~ *tx_fifo/rgray_reg* || NAME =~ *tx_fifo/rbin_reg*)}] \
    -to [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *tx_fifo/rgray_w1_reg*}]
set_bus_skew 16.667 \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && (NAME =~ *tx_fifo/rgray_reg* || NAME =~ *tx_fifo/rbin_reg*)}] \
    -to [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *tx_fifo/rgray_w1_reg*}]
set_max_delay -datapath_only 16.667 \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && (NAME =~ *rx_fifo/wgray_reg* || NAME =~ *rx_fifo/wbin_reg*)}] \
    -to [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *rx_fifo/wgray_r1_reg*}]
set_bus_skew 16.667 \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && (NAME =~ *rx_fifo/wgray_reg* || NAME =~ *rx_fifo/wbin_reg*)}] \
    -to [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *rx_fifo/wgray_r1_reg*}]
set_max_delay -datapath_only 10.000 \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && (NAME =~ *rx_fifo/rgray_reg* || NAME =~ *rx_fifo/rbin_reg*)}] \
    -to [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *rx_fifo/rgray_w1_reg*}]
set_bus_skew 10.000 \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && (NAME =~ *rx_fifo/rgray_reg* || NAME =~ *rx_fifo/rbin_reg*)}] \
    -to [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *rx_fifo/rgray_w1_reg*}]
# RX uses distributed dual-port RAM. A write becomes readable only after
# wgray_r1/r2 and the empty flag have sampled its pointer; the read register
# therefore cannot capture the newly written word before two full core clocks.
# Bound write-clock-to-read-data transit to one 100MHz cycle. The RAM read
# address paths remain ordinary core-clock paths. USB/core phase is arbitrary.
set_max_delay -datapath_only 10.000 \
    -from [get_pins -hier -filter {REF_PIN_NAME == CLK && NAME =~ *rx_fifo/memory_reg*/CLK}] \
    -to [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *rx_fifo/m_data_reg*}]
set_max_delay -datapath_only 10.000 \
    -from [get_cells -hier -regexp {.*stats_mailbox/held_data_reg\[.*}] \
    -to [get_cells -hier -regexp {.*stats_mailbox/m_data_reg\[.*}]
set_false_path -to [get_pins -hier -regexp {.*stats_mailbox/(ack_s1|request_m1)_reg/D}]
set_false_path -to [get_pins -hier -regexp {.*clock_guard/heartbeat_sync_reg\[0\]/D}]
# Assertion is asynchronous; deassertion is synchronized in each clock domain.
set_false_path -to [get_pins -hier -regexp {.*(usb_reset_pipe|reset_pipe)_reg\[.*\]/CLR}]

# T is enabled in TURN, WR launches in WRITE, and FTDI samples one edge later.
# Camera pixel FIFO Gray pointers: bound physical skew within the source
# cycle. Each diagnostic counter increments by at most one per PCLK.
set_max_delay -datapath_only [get_property PERIOD [get_clocks cam_clk]] \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && (NAME =~ *pixel_fifo/wgray_reg* || NAME =~ *pixel_fifo/wbin_reg*)}] \
    -to [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *pixel_fifo/wgray_r1_reg*}]
set_bus_skew [get_property PERIOD [get_clocks cam_clk]] \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && (NAME =~ *pixel_fifo/wgray_reg* || NAME =~ *pixel_fifo/wbin_reg*)}] \
    -to [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *pixel_fifo/wgray_r1_reg*}]
set_max_delay -datapath_only 10.000 \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && (NAME =~ *pixel_fifo/rgray_reg* || NAME =~ *pixel_fifo/rbin_reg*)}] \
    -to [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *pixel_fifo/rgray_w1_reg*}]
set_bus_skew 10.000 \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && (NAME =~ *pixel_fifo/rgray_reg* || NAME =~ *pixel_fifo/rbin_reg*)}] \
    -to [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *pixel_fifo/rgray_w1_reg*}]
# Keep native XDC commands (foreach is not accepted by read_xdc). The Gray
# MSB may share a binary-counter register after synthesis; include both.
set_max_delay -datapath_only [get_property PERIOD [get_clocks cam_clk]] \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && (NAME =~ *capture/*_gray_reg* || NAME =~ *capture/*_bin_reg*)}] \
    -to [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *capture/*_c1_reg*}]
set_bus_skew [get_property PERIOD [get_clocks cam_clk]] \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && (NAME =~ *capture/*_gray_reg* || NAME =~ *capture/*_bin_reg*)}] \
    -to [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *capture/*_c1_reg*}]
set_false_path -to [get_pins -hier -regexp {.*capture/(enable_sync|enable_seen_sync|ack_sync|req_sync|active_sync)_reg\[0\]/D}]
set_false_path -to [get_pins -hier -regexp {.*(wreset_pipe|rreset_pipe)_reg\[.*\]/CLR}]
# Fault flush has independent async-assert/sync-release preset pipelines;
# combine reset sources only after they have been synchronized locally.
set_false_path -to [get_pins -hier -regexp {.*(wflush_pipe|rflush_pipe)_reg\[.*\]/PRE}]
set_false_path -to [get_pins -hier -regexp {.*capture/.*_reg(\[.*\])?/CLR}]
set_false_path -from [get_ports cam_sda] -to [get_pins -hier -filter {NAME =~ *u_sccb/sda_meta_reg/D}]
set_false_path -to [get_pins -hier -regexp {.*sampling_lock_sync_reg\[0\]/D}]
# This also applies after reset (initial state TURN). DATA/WR/RD/OE remain
# single-cycle. Release precedes OE by one full cycle; the build separately
# signs off all eight T clock-to-pad datapaths <=8ns for that release deadline.
set_multicycle_path 2 -setup \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *link/tristate_n_reg*}] \
    -to [get_ports {usb_data[*]}]
set_multicycle_path 1 -hold \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *link/tristate_n_reg*}] \
    -to [get_ports {usb_data[*]}]
