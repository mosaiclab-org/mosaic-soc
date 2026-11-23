// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// MOSAIC-SoC -- the chip of configs/mosaic_block_efpga.yaml: Block A's SoC with the
// eFPGA fabric of configs/efpga/small.csv as a hard macro, inside its own ring of
// GF180MCU pads (flow/librelane/slots/slot_1x1_efpga.yaml, hardened by
// flow/librelane/scripts/efpga_block.sh with EFPGA_CHIP; docs/efpga.md).
//
// mosaic_block_efpga.sv with its pins replaced by pad cells: the same SoC, the same
// terminations of its other ports. The pads follow Block A's policy
// (padframe/pad_policy.py): the clock through the Schmitt input in_s, the other
// inputs through in_c, reset pulled down so that an undriven reset holds the chip
// in reset; outputs through bi_t at 12 mA, input off; a bidirectional pad has its
// input on only while it does not drive (IE = ~OE), since the PDK's control table
// disallows IE and OE both high. The fabric's pads differ in two ways. They are
// pulled down, so that a pad nothing drives reads 0 instead of floating. And with
// its input off while it drives, a pad would read 0 to a design that drives it,
// where every bench of the RTL, whose pad is a wire, reads the driven value; so
// while the fabric drives a pad it is given what it drives, as in RTL.
//
// The pads' power pins are connected by the flow's power grid (the ring of the
// core to the pads); USE_POWER_PINS names them for a netlist with power.

`default_nettype none

module mosaic_chip_efpga
  import obi_pkg::*;
  import reg_pkg::*;
  import fifo_pkg::*;
#(

parameter EXT_XBAR_NMASTER = 0,
    parameter AO_SPC_NUM = 0,
    parameter EXT_HARTS = 0,
    
    parameter AO_SPC_NUM_RND = AO_SPC_NUM == 0 ? 0 : AO_SPC_NUM - 1,
    parameter EXT_XBAR_NMASTER_RND = EXT_XBAR_NMASTER == 0 ? 1 : EXT_XBAR_NMASTER,
    parameter EXT_DOMAINS_RND = mosaic_soc_pkg::EXTERNAL_DOMAINS == 0 ? 1 : mosaic_soc_pkg::EXTERNAL_DOMAINS,
    parameter NEXT_INT_RND = mosaic_soc_pkg::NEXT_INT == 0 ? 1 : mosaic_soc_pkg::NEXT_INT,
    parameter EXT_HARTS_RND = EXT_HARTS == 0 ? 1 : EXT_HARTS
) (
`ifdef USE_POWER_PINS
    inout  wire       VDD,
    inout  wire       VSS,
`endif
    inout  wire       clk_PAD,
    inout  wire       rst_n_PAD,
    inout  wire       boot_select_PAD,
    inout  wire       execute_from_flash_PAD,
    inout  wire       spi_flash_sck_PAD,
    inout  wire       spi_flash_cs_PAD,
    inout  wire [3:0] spi_flash_sd_PAD,
    inout  wire       uart_rx_PAD,
    inout  wire       uart_tx_PAD,
    inout  wire       status_valid_PAD,
    inout  wire [6:0] status_PAD,
    inout  wire [7:0] efpga_PAD
);

  // The eXtension interface: six ports that slang/verilator refuse to leave
  // unconnected. One bus, all six tied to it -- no XIF accelerator is present.
  if_xif xif_bus ();

  // What the SoC instance below names: the pins of mosaic_block_efpga.
  logic clk_i, rst_ni, boot_select_i, execute_from_flash_i, uart_rx_i, uart_tx_o;
  logic spi_flash_sck_o, spi_flash_cs_o, status_valid_o;
  logic [6:0] status_o;
  logic [3:0] flash_sd_o, flash_sd_oe, flash_sd_i;
  logic [7:0] efpga_pad_o, efpga_pad_oe, efpga_pad_i, efpga_pad_y;

`ifdef USE_POWER_PINS
`define MOSAIC_PAD_POWER .DVDD(VDD), .DVSS(VSS), .VDD(VDD), .VSS(VSS),
`else
`define MOSAIC_PAD_POWER
`endif

  // ---- power: one supply, 5 V, for the core and the pads ------------------
  for (genvar i = 0; i < 5; i++) begin : dvdd
    (* keep *) gf180mcu_ws_io__dvdd pad (
`ifdef USE_POWER_PINS
        .DVDD(VDD), .DVSS(VSS), .VSS(VSS)
`endif
    );
  end
  for (genvar i = 0; i < 5; i++) begin : dvss
    (* keep *) gf180mcu_ws_io__dvss pad (
`ifdef USE_POWER_PINS
        .DVDD(VDD), .DVSS(VSS), .VDD(VDD)
`endif
    );
  end

  // ---- inputs -------------------------------------------------------------
  gf180mcu_fd_io__in_s clk_pad (`MOSAIC_PAD_POWER .PAD(clk_PAD), .Y(clk_i), .PU(1'b0), .PD(1'b0));
  gf180mcu_fd_io__in_c rst_n_pad (`MOSAIC_PAD_POWER .PAD(rst_n_PAD), .Y(rst_ni), .PU(1'b0), .PD(1'b1));
  gf180mcu_fd_io__in_c boot_select_pad (`MOSAIC_PAD_POWER .PAD(boot_select_PAD), .Y(boot_select_i), .PU(1'b0), .PD(1'b0));
  gf180mcu_fd_io__in_c execute_from_flash_pad (`MOSAIC_PAD_POWER .PAD(execute_from_flash_PAD), .Y(execute_from_flash_i), .PU(1'b0), .PD(1'b0));
  gf180mcu_fd_io__in_c uart_rx_pad (`MOSAIC_PAD_POWER .PAD(uart_rx_PAD), .Y(uart_rx_i), .PU(1'b0), .PD(1'b0));

  // ---- outputs: 12 mA (PDRV1/PDRV0 = 1/0), input off, its Y unused --------
  logic [10:0] out_d;
  wire  [10:0] out_pad;
  assign out_d = {status_o, status_valid_o, uart_tx_o, spi_flash_cs_o, spi_flash_sck_o};
  assign {status_PAD, status_valid_PAD, uart_tx_PAD, spi_flash_cs_PAD, spi_flash_sck_PAD} = out_pad;
  for (genvar i = 0; i < 11; i++) begin : outputs
    gf180mcu_fd_io__bi_t pad (`MOSAIC_PAD_POWER
        .PAD(out_pad[i]), .A(out_d[i]), .OE(1'b1), .IE(1'b0), .Y(),
        .CS(1'b0), .SL(1'b0), .PU(1'b0), .PD(1'b0), .PDRV0(1'b0), .PDRV1(1'b1));
  end

  // ---- QSPI data ----------------------------------------------------------
  for (genvar i = 0; i < 4; i++) begin : flash_sd
    gf180mcu_fd_io__bi_t pad (`MOSAIC_PAD_POWER
        .PAD(spi_flash_sd_PAD[i]), .A(flash_sd_o[i]), .OE(flash_sd_oe[i]), .IE(~flash_sd_oe[i]),
        .Y(flash_sd_i[i]), .CS(1'b0), .SL(1'b0), .PU(1'b0), .PD(1'b0), .PDRV0(1'b0), .PDRV1(1'b1));
  end

  // ---- the eFPGA's pads ---------------------------------------------------
  for (genvar i = 0; i < 8; i++) begin : efpga
    gf180mcu_fd_io__bi_t pad (`MOSAIC_PAD_POWER
        .PAD(efpga_PAD[i]), .A(efpga_pad_o[i]), .OE(efpga_pad_oe[i]), .IE(~efpga_pad_oe[i]),
        .Y(efpga_pad_y[i]), .CS(1'b0), .SL(1'b0), .PU(1'b0), .PD(1'b1), .PDRV0(1'b0), .PDRV1(1'b1));
    assign efpga_pad_i[i] = efpga_pad_oe[i] ? efpga_pad_o[i] : efpga_pad_y[i];
  end
`undef MOSAIC_PAD_POWER

  // --- power-switch handshakes (see header) --------------------------------
  logic cpu_subsystem_powergate_switch_no_int;
  logic peripheral_subsystem_powergate_switch_no_int;
  logic [EXT_DOMAINS_RND-1:0] external_subsystem_powergate_switch_no_int;

  logic [31:0] exit_value_int;
  assign status_o = exit_value_int[6:0];

  logic jtag_tck_i_tie = '0;
  logic jtag_tms_i_tie = '0;
  logic jtag_trst_ni_tie = '0;
  logic jtag_tdi_i_tie = '0;
  logic ddr_rcv_clk_i_tie = '0;
  logic gpio_0_i_tie = '0;
  logic gpio_1_i_tie = '0;
  logic ddr_rcv_0_i_tie = '0;
  logic gpio_2_i_tie = '0;
  logic ddr_rcv_1_i_tie = '0;
  logic gpio_3_i_tie = '0;
  logic ddr_rcv_2_i_tie = '0;
  logic gpio_4_i_tie = '0;
  logic gpio_5_i_tie = '0;
  logic gpio_6_i_tie = '0;
  logic ddr_rcv_3_i_tie = '0;
  logic gpio_7_i_tie = '0;
  logic gpio_8_i_tie = '0;
  logic gpio_9_i_tie = '0;
  logic gpio_10_i_tie = '0;
  logic gpio_11_i_tie = '0;
  logic gpio_12_i_tie = '0;
  logic gpio_13_i_tie = '0;
  logic spi_flash_cs_1_i_tie = '0;
  logic spi_sck_i_tie = '0;
  logic spi_cs_0_i_tie = '0;
  logic spi_cs_1_i_tie = '0;
  logic spi_sd_0_i_tie = '0;
  logic spi_sd_1_i_tie = '0;
  logic spi_sd_2_i_tie = '0;
  logic spi_sd_3_i_tie = '0;
  logic spi_slave_sck_i_tie = '0;
  logic gpio_14_i_tie = '0;
  logic spi_slave_cs_i_tie = '0;
  logic gpio_15_i_tie = '0;
  logic spi_slave_miso_i_tie = '0;
  logic gpio_16_i_tie = '0;
  logic spi_slave_mosi_i_tie = '0;
  logic gpio_17_i_tie = '0;
  logic pdm2pcm_pdm_i_tie = '0;
  logic gpio_18_i_tie = '0;
  logic pdm2pcm_clk_i_tie = '0;
  logic gpio_19_i_tie = '0;
  logic i2s_sck_i_tie = '0;
  logic gpio_20_i_tie = '0;
  logic i2s_ws_i_tie = '0;
  logic gpio_21_i_tie = '0;
  logic i2s_sd_i_tie = '0;
  logic gpio_22_i_tie = '0;
  logic spi2_cs_0_i_tie = '0;
  logic gpio_23_i_tie = '0;
  logic spi2_cs_1_i_tie = '0;
  logic gpio_24_i_tie = '0;
  logic spi2_sck_i_tie = '0;
  logic gpio_25_i_tie = '0;
  logic spi2_sd_0_i_tie = '0;
  logic gpio_26_i_tie = '0;
  logic spi2_sd_1_i_tie = '0;
  logic gpio_27_i_tie = '0;
  logic spi2_sd_2_i_tie = '0;
  logic gpio_28_i_tie = '0;
  logic spi2_sd_3_i_tie = '0;
  logic gpio_29_i_tie = '0;
  logic i2c_scl_i_tie = '0;
  logic gpio_31_i_tie = '0;
  logic i2c_sda_i_tie = '0;
  logic gpio_30_i_tie = '0;
  logic [31:0] hart_id_i_tie = '0;
  logic [31:0] xheep_instance_id_i_tie = '0;
  reg_rsp_t pad_resp_i_tie = '0;
  obi_req_t  [EXT_XBAR_NMASTER_RND-1:0] ext_xbar_master_req_i_tie = '0;
  reg_req_t  [AO_SPC_NUM_RND:0] ext_ao_peripheral_slave_req_i_tie = '0;
  obi_resp_t ext_core_instr_resp_i_tie = '0;
  obi_resp_t ext_core_data_resp_i_tie = '0;
  obi_resp_t ext_debug_master_resp_i_tie = '0;
  obi_resp_t [mosaic_soc_pkg::DMA_NUM_MASTER_PORTS-1:0] ext_dma_read_resp_i_tie = '0;
  obi_resp_t [mosaic_soc_pkg::DMA_NUM_MASTER_PORTS-1:0] ext_dma_write_resp_i_tie = '0;
  fifo_resp_t [mosaic_soc_pkg::DMA_CH_NUM-1:0] hw_fifo_resp_i_tie = '0;
  logic [mosaic_soc_pkg::DMA_CH_NUM-1:0] ext_dma_stop_i_tie = '0;
  logic [mosaic_soc_pkg::DMA_CH_NUM-1:0] hw_fifo_done_i_tie = '0;
  reg_rsp_t ext_peripheral_slave_resp_i_tie = '0;
  logic [NEXT_INT_RND-1:0] intr_vector_ext_i_tie = '0;
  logic intr_ext_peripheral_i_tie = '0;
  logic [mosaic_soc_pkg::DMA_CH_NUM-1:0] ext_dma_slot_tx_i_tie = '0;
  logic [mosaic_soc_pkg::DMA_CH_NUM-1:0] ext_dma_slot_rx_i_tie = '0;

  // Unused mosaic_soc OUTPUTS are omitted from this instantiation rather
  // than bound to an empty reference: synthesis then prunes the logic that
  // drove them, which is the point of trimming the interface. Unused INPUTS
  // are tied to explicit constants below.
  mosaic_soc i_mosaic_soc (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .boot_select_i(boot_select_i),
      .execute_from_flash_i(execute_from_flash_i),
      .uart_rx_i(uart_rx_i),
      .uart_tx_o(uart_tx_o),
      .exit_valid_o(status_valid_o),
      .exit_value_o(exit_value_int),
      .spi_flash_sck_o(spi_flash_sck_o),
      .spi_flash_sck_i(1'b0),
      .spi_flash_cs_0_o(spi_flash_cs_o),
      .spi_flash_cs_0_i(1'b0),
      .spi_flash_sd_0_o(flash_sd_o[0]),
      .spi_flash_sd_0_oe_o(flash_sd_oe[0]),
      .spi_flash_sd_0_i(flash_sd_i[0]),
      .spi_flash_sd_1_o(flash_sd_o[1]),
      .spi_flash_sd_1_oe_o(flash_sd_oe[1]),
      .spi_flash_sd_1_i(flash_sd_i[1]),
      .spi_flash_sd_2_o(flash_sd_o[2]),
      .spi_flash_sd_2_oe_o(flash_sd_oe[2]),
      .spi_flash_sd_2_i(flash_sd_i[2]),
      .spi_flash_sd_3_o(flash_sd_o[3]),
      .spi_flash_sd_3_oe_o(flash_sd_oe[3]),
      .spi_flash_sd_3_i(flash_sd_i[3]),
      .cpu_subsystem_powergate_switch_no(cpu_subsystem_powergate_switch_no_int),
      .cpu_subsystem_powergate_switch_ack_ni(cpu_subsystem_powergate_switch_no_int),
      .peripheral_subsystem_powergate_switch_no(peripheral_subsystem_powergate_switch_no_int),
      .peripheral_subsystem_powergate_switch_ack_ni(peripheral_subsystem_powergate_switch_no_int),
      .external_subsystem_powergate_switch_no(external_subsystem_powergate_switch_no_int),
      .external_subsystem_powergate_switch_ack_ni(external_subsystem_powergate_switch_no_int),
      .jtag_tck_i(jtag_tck_i_tie),
      .jtag_tms_i(jtag_tms_i_tie),
      .jtag_trst_ni(jtag_trst_ni_tie),
      .jtag_tdi_i(jtag_tdi_i_tie),
      .ddr_rcv_clk_i(ddr_rcv_clk_i_tie),
      .gpio_0_i(gpio_0_i_tie),
      .gpio_1_i(gpio_1_i_tie),
      .ddr_rcv_0_i(ddr_rcv_0_i_tie),
      .gpio_2_i(gpio_2_i_tie),
      .ddr_rcv_1_i(ddr_rcv_1_i_tie),
      .gpio_3_i(gpio_3_i_tie),
      .ddr_rcv_2_i(ddr_rcv_2_i_tie),
      .gpio_4_i(gpio_4_i_tie),
      .gpio_5_i(gpio_5_i_tie),
      .gpio_6_i(gpio_6_i_tie),
      .ddr_rcv_3_i(ddr_rcv_3_i_tie),
      .gpio_7_i(gpio_7_i_tie),
      .gpio_8_i(gpio_8_i_tie),
      .gpio_9_i(gpio_9_i_tie),
      .gpio_10_i(gpio_10_i_tie),
      .gpio_11_i(gpio_11_i_tie),
      .gpio_12_i(gpio_12_i_tie),
      .gpio_13_i(gpio_13_i_tie),
      .spi_flash_cs_1_i(spi_flash_cs_1_i_tie),
      .spi_sck_i(spi_sck_i_tie),
      .spi_cs_0_i(spi_cs_0_i_tie),
      .spi_cs_1_i(spi_cs_1_i_tie),
      .spi_sd_0_i(spi_sd_0_i_tie),
      .spi_sd_1_i(spi_sd_1_i_tie),
      .spi_sd_2_i(spi_sd_2_i_tie),
      .spi_sd_3_i(spi_sd_3_i_tie),
      .spi_slave_sck_i(spi_slave_sck_i_tie),
      .gpio_14_i(gpio_14_i_tie),
      .spi_slave_cs_i(spi_slave_cs_i_tie),
      .gpio_15_i(gpio_15_i_tie),
      .spi_slave_miso_i(spi_slave_miso_i_tie),
      .gpio_16_i(gpio_16_i_tie),
      .spi_slave_mosi_i(spi_slave_mosi_i_tie),
      .gpio_17_i(gpio_17_i_tie),
      .pdm2pcm_pdm_i(pdm2pcm_pdm_i_tie),
      .gpio_18_i(gpio_18_i_tie),
      .pdm2pcm_clk_i(pdm2pcm_clk_i_tie),
      .gpio_19_i(gpio_19_i_tie),
      .i2s_sck_i(i2s_sck_i_tie),
      .gpio_20_i(gpio_20_i_tie),
      .i2s_ws_i(i2s_ws_i_tie),
      .gpio_21_i(gpio_21_i_tie),
      .i2s_sd_i(i2s_sd_i_tie),
      .gpio_22_i(gpio_22_i_tie),
      .spi2_cs_0_i(spi2_cs_0_i_tie),
      .gpio_23_i(gpio_23_i_tie),
      .spi2_cs_1_i(spi2_cs_1_i_tie),
      .gpio_24_i(gpio_24_i_tie),
      .spi2_sck_i(spi2_sck_i_tie),
      .gpio_25_i(gpio_25_i_tie),
      .spi2_sd_0_i(spi2_sd_0_i_tie),
      .gpio_26_i(gpio_26_i_tie),
      .spi2_sd_1_i(spi2_sd_1_i_tie),
      .gpio_27_i(gpio_27_i_tie),
      .spi2_sd_2_i(spi2_sd_2_i_tie),
      .gpio_28_i(gpio_28_i_tie),
      .spi2_sd_3_i(spi2_sd_3_i_tie),
      .gpio_29_i(gpio_29_i_tie),
      .i2c_scl_i(i2c_scl_i_tie),
      .gpio_31_i(gpio_31_i_tie),
      .i2c_sda_i(i2c_sda_i_tie),
      .gpio_30_i(gpio_30_i_tie),
      .hart_id_i(hart_id_i_tie),
      .xheep_instance_id_i(xheep_instance_id_i_tie),
      .pad_resp_i(pad_resp_i_tie),
      .ext_xbar_master_req_i(ext_xbar_master_req_i_tie),
      .ext_ao_peripheral_slave_req_i(ext_ao_peripheral_slave_req_i_tie),
      .ext_core_instr_resp_i(ext_core_instr_resp_i_tie),
      .ext_core_data_resp_i(ext_core_data_resp_i_tie),
      .ext_debug_master_resp_i(ext_debug_master_resp_i_tie),
      .ext_dma_read_resp_i(ext_dma_read_resp_i_tie),
      .ext_dma_write_resp_i(ext_dma_write_resp_i_tie),
      .hw_fifo_resp_i(hw_fifo_resp_i_tie),
      .ext_dma_stop_i(ext_dma_stop_i_tie),
      .hw_fifo_done_i(hw_fifo_done_i_tie),
      .ext_peripheral_slave_resp_i(ext_peripheral_slave_resp_i_tie),
      .intr_vector_ext_i(intr_vector_ext_i_tie),
      .intr_ext_peripheral_i(intr_ext_peripheral_i_tie),
      .ext_dma_slot_tx_i(ext_dma_slot_tx_i_tie),
      .ext_dma_slot_rx_i(ext_dma_slot_rx_i_tie),
      .efpga_pad_0_i(efpga_pad_i[0]),
      .efpga_pad_0_o(efpga_pad_o[0]),
      .efpga_pad_0_oe_o(efpga_pad_oe[0]),
      .efpga_pad_1_i(efpga_pad_i[1]),
      .efpga_pad_1_o(efpga_pad_o[1]),
      .efpga_pad_1_oe_o(efpga_pad_oe[1]),
      .efpga_pad_2_i(efpga_pad_i[2]),
      .efpga_pad_2_o(efpga_pad_o[2]),
      .efpga_pad_2_oe_o(efpga_pad_oe[2]),
      .efpga_pad_3_i(efpga_pad_i[3]),
      .efpga_pad_3_o(efpga_pad_o[3]),
      .efpga_pad_3_oe_o(efpga_pad_oe[3]),
      .efpga_pad_4_i(efpga_pad_i[4]),
      .efpga_pad_4_o(efpga_pad_o[4]),
      .efpga_pad_4_oe_o(efpga_pad_oe[4]),
      .efpga_pad_5_i(efpga_pad_i[5]),
      .efpga_pad_5_o(efpga_pad_o[5]),
      .efpga_pad_5_oe_o(efpga_pad_oe[5]),
      .efpga_pad_6_i(efpga_pad_i[6]),
      .efpga_pad_6_o(efpga_pad_o[6]),
      .efpga_pad_6_oe_o(efpga_pad_oe[6]),
      .efpga_pad_7_i(efpga_pad_i[7]),
      .efpga_pad_7_o(efpga_pad_o[7]),
      .efpga_pad_7_oe_o(efpga_pad_oe[7]),
      .xif_compressed_if(xif_bus),
      .xif_issue_if(xif_bus),
      .xif_commit_if(xif_bus),
      .xif_mem_if(xif_bus),
      .xif_mem_result_if(xif_bus),
      .xif_result_if(xif_bus)
  );

endmodule

`default_nettype wire
