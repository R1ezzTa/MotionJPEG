# Implementation-only CDC constraints: require mapped synchronizer registers.
# Do not false-path clock groups: Gray bus transit and skew remain bounded.
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
# This also applies after reset (initial state TURN). DATA/WR/RD/OE remain
# single-cycle. Release precedes OE by one full cycle; the build separately
# signs off all eight T clock-to-pad datapaths <=8ns for that release deadline.
set_multicycle_path 2 -setup \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *link/tristate_n_reg*}] \
    -to [get_ports {usb_data[*]}]
set_multicycle_path 1 -hold \
    -from [get_cells -hier -filter {IS_SEQUENTIAL == 1 && NAME =~ *link/tristate_n_reg*}] \
    -to [get_ports {usb_data[*]}]
