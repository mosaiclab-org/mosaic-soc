// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tb_efpga_soc: a SoC hardened with the eFPGA fabric as a macro
// (flow/librelane/scripts/efpga_block.sh), its netlist around the fabric's
// netlist, through its pins only: it boots from the flash model of the RTL bench,
// executing in place, and the image (tb/mosaic_soc/run_generic.sh with
// EFPGA_DESIGN) loads a design into the fabric, checks it and exits through
// soc_ctrl, which drives status_valid_o and status_o. tb/efpga/run_soc_block.sh
// runs it.
//
// Pass criterion: "TB PASS", once status_valid_o rose with status_o 0
// and the fabric's pads carrying the 0xA5 the image leaves in tb/efpga/shell_regs.v,
// driven by the design. A failure prints "TB FAIL reason=<r>".
`timescale 1ns / 1ps
`default_nettype none

module tb_efpga_soc;
    logic clk = 1'b0, rst_n = 1'b0;
    wire uart_tx, spi_sck, spi_csb, status_valid;
    wire [3:0] spi_sd;
    wire [6:0] status;
    wire [7:0] pads;
    string firmware;
    int maxcycles;
    longint cycles = 0;

    `TOP dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .boot_select_i(1'b1),         // boot from flash
        .execute_from_flash_i(1'b1),  // through the memory-mapped window
        .uart_rx_i(1'b1),
        .uart_tx_o(uart_tx),
        .spi_flash_sck_o(spi_sck),
        .spi_flash_cs_o(spi_csb),
        .spi_flash_sd_io(spi_sd),
        .status_valid_o(status_valid),
        .status_o(status),
        .efpga_pad_io(pads)
    );

    spiflash flash_i (
        .csb(spi_csb),
        .clk(spi_sck),
        .io0(spi_sd[0]),
        .io1(spi_sd[1]),
        .io2(spi_sd[2]),
        .io3(spi_sd[3])
    );

    always #25 clk = ~clk;  // the 50 ns the block was hardened for
    always @(posedge clk) cycles <= cycles + 1;

    task automatic fail(input string reason);
        $display("TB FAIL reason=%0s cycles=%0d", reason, cycles);
        $fatal(1, "TB FAIL");
    endtask

    initial begin
        if (!$value$plusargs("firmware=%s", firmware)) fail("firmware_plusarg_missing");
        if (!$value$plusargs("maxcycles=%d", maxcycles)) maxcycles = 2_000_000;
        for (int unsigned i = 0; i < 16 * 1024 * 1024; i++) flash_i.memory[i] = 8'h00;
        $readmemh(firmware, flash_i.memory);
        repeat (20) @(posedge clk);
        @(negedge clk);  // released away from the capture edge
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n && status_valid === 1'b1) begin
            $display("status_o = 0x%02h, pads = 0x%02h after %0d cycles", status, pads, cycles);
            if (status !== 7'd0) fail("exit_value");
            if (pads !== 8'hA5) fail("pads");
            $display("TB PASS cycles=%0d", cycles);
            $finish;
        end
        if (cycles > maxcycles) fail("watchdog");
    end
endmodule
`default_nettype wire
