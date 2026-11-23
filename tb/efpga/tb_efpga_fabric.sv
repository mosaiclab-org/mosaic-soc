// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// The FABulous fabric core `eFPGA` simulated alone, configured with a real
// bitstream. The bench is the configuration loader: it parses a bit_gen .bin
// file and drives FrameData / FrameStrobe itself, as the loader of
// hw/efpga/mosaic_efpga.sv does with the frames in another order.
// FABulous's eFPGA_top and its configuration logic are not compiled.
//
// The fabric is the `small` preset (8 pads); the user design is counter8_en.
// The geometry comes from the generated RTL (tb/efpga/run.sh passes it):
//   -DROWS=<logic rows> -DCOLS=<columns> -DFBPR=<frame bits per row>
//   -DMFPC=<frames per column>
//
// Plusargs:
//   +bitstream=<file.bin>  bit_gen output (required unless +no_bitstream)
//   +no_bitstream          negative control: load nothing
//   +clk_during_cfg        keep UserCLK running while the frames are loaded
//
// Pass criterion: "TB PASS", printed only after the fabric matched the RTL
// counter in every cycle and shows the exact final count. Every failure prints
// "TB FAIL reason=<r>" and ends with $fatal. The watchdog only covers a hang in
// which simulated time advances: a wrong bitstream can make the fabric
// oscillate in zero time, so tb/efpga/run.sh also limits each run's wall time.
`timescale 1ns / 1ps
`default_nettype none

module tb_efpga_fabric;
    localparam int ROWS = `ROWS;  // rows that hold configuration: Y1..Y<ROWS>
    localparam int COLS = `COLS;
    localparam int FBPR = `FBPR;
    localparam int MFPC = `MFPC;
    localparam int PADS = 2 * ROWS;  // two W_IO pads per row
    // The bitstream format of bit_gen (FABulous's ConfigFSM reads the same).
    localparam logic [31:0] SYNC = 32'hFAB0_FAB1;
    localparam int COL_W = 5;  // column of a frame: header[31:27]
    localparam int DESYNC_BIT = 20;  // header bit that ends the bitstream
    localparam int MAX_BYTES = 65536;
    localparam int CYCLES = 600;
    localparam logic [7:0] FINAL = 8'd199;  // the count after the stimulus below

    // The names are those of eFPGA_top's port map, which efpga_inst.vh is.
    logic                     clk_free = 1'b0;
    logic                     clk_en = 1'b0;
    wire                      CLK = clk_free & clk_en;  // UserCLK
    logic [FBPR*(ROWS+2)-1:0] FrameData = '0;
    logic [    MFPC*COLS-1:0] FrameSelect = '0;  // the core's FrameStrobe
    logic [         PADS-1:0] O_top = '0;  // pads -> fabric
    wire  [         PADS-1:0] I_top;  // fabric -> pads
    wire  [         PADS-1:0] T_top;
    wire [4*ROWS-1:0] A_config_C, B_config_C, Config_accessC;
    wire  [      16*ROWS-1:0] RAM2FAB_D_I = '0;
    wire  [      16*ROWS-1:0] FAB2RAM_D_O;
    wire  [       8*ROWS-1:0] FAB2RAM_A_O;
    wire  [       4*ROWS-1:0] FAB2RAM_C_O;

    // `eFPGA eFPGA_inst (...)`, cut from the generated eFPGA_top.v by efpga_gen.py.
    `include "efpga_inst.vh"

    // Reference: the same RTL the bitstream was compiled from.
    wire [7:0] I_gold, oeb_gold;
    counter8_en gold_i (
        .clk   (CLK),
        .io_in (O_top),
        .io_out(I_gold),
        .io_oeb(oeb_gold)
    );
    wire [7:0] T_gold = ~oeb_gold;  // the pad cell inverts the output enable

    always #5 clk_free = ~clk_free;

    logic [7:0] bs[MAX_BYTES];
    logic [8*1024-1:0] bs_path;  // a shorter vector silently truncates a long path
    int fd, nbytes, nwords, w, col, frames, errors, oe_errors;
    logic [31:0] hdr;
    logic [MFPC*COLS-1:0] strobed = '0;  // every strobe line the loader pulsed

    function automatic logic [31:0] word(input int idx);
        return {bs[4*idx], bs[4*idx+1], bs[4*idx+2], bs[4*idx+3]};  // big-endian
    endfunction

    task automatic fail(input logic [8*32-1:0] reason);
        $display("TB FAIL reason=%0s t=%0t", reason, $time);
        $fatal(1, "TB FAIL");
    endtask

    // One frame at the core boundary: FrameData stable, then the strobe bits of
    // one column high, then low, with FrameData held across the falling edge.
    // The configuration cells are latches, transparent while their strobe is 1.
    task automatic load_bitstream;
        w = 0;
        while (w < nwords && word(w) !== SYNC) w++;
        if (w >= nwords) fail("no_sync_word");
        w++;
        if (w >= nwords) fail("no_desync_word");
        hdr = word(w);
        while (hdr[DESYNC_BIT] !== 1'b1) begin
            if (w + ROWS >= nwords) fail("truncated_frame");
            col = hdr >> (32 - COL_W);
            if (col >= COLS) fail("column_out_of_range");
            // First data word -> row Y<ROWS>, last -> row Y1. Y0 and Y<ROWS+1>
            // are the terminal rows and hold no configuration.
            for (int r = ROWS; r >= 1; r--) FrameData[FBPR*r+:FBPR] = word(w + 1 + ROWS - r);
            #2 FrameSelect[MFPC*col+:MFPC] = hdr[MFPC-1:0];
            strobed |= FrameSelect;
            #4 FrameSelect = '0;
            #2 frames++;
            w += 1 + ROWS;
            if (w >= nwords) fail("no_desync_word");
            hdr = word(w);
        end
    endtask

    initial begin
        frames = 0;
        errors = 0;
        oe_errors = 0;
        if (PADS != 8) fail("bench_needs_8_pads");
        clk_en = $test$plusargs("clk_during_cfg");
        #20;
        if ($test$plusargs("no_bitstream")) begin
            $display("negative control: no bitstream loaded");
        end else begin
            if (!$value$plusargs("bitstream=%s", bs_path)) fail("no_bitstream_plusarg");
            fd = $fopen(bs_path, "rb");
            if (fd == 0) fail("cannot_open_bitstream");
            nbytes = $fread(bs, fd);
            $fclose(fd);
            nwords = nbytes / 4;
            if (nbytes <= 0 || nbytes % 4 != 0) fail("bitstream_size");
            load_bitstream();
            $display("loaded %0d frames from %0d bytes", frames, nbytes);
            // Every latch is enabled by one strobe line of its column and every
            // frame carries all rows, so once every strobe line was pulsed every
            // latch was written: the result cannot depend on the power-up state.
            if (strobed !== '1) fail("strobe_lines_not_all_pulsed");
        end

        // Release the user design: clock on, counter enabled and in reset.
        @(negedge clk_free);
        clk_en = 1'b1;
        O_top  = 8'd3;  // io_in[0] = rst, io_in[1] = en
        repeat (5) @(negedge clk_free);
        // Counting alone leaves much of the design unobserved, so in cycles
        // 100..109 en is low and the count must hold, in cycle 400 a reset
        // restarts it, and in cycle 450 a reset with en low must leave it
        // alone (en gates the reset). The count wraps once, in cycle 266:
        // 99 held, +290 = 389 = 133 mod 256, reset, +49, held, +150 = FINAL.
        for (int k = 1; k <= CYCLES; k++) begin
            O_top[1] = !((k >= 100 && k < 110) || k == 450);  // en
            O_top[0] = (k == 400 || k == 450);  // rst
            @(negedge clk_free);
            if (I_top !== I_gold || T_top !== T_gold) begin
                if (errors + oe_errors < 5)
                    $display("mismatch cycle %0d: I_top=%h gold=%h  T_top=%h gold=%h",
                             k, I_top, I_gold, T_top, T_gold);
                if (I_top !== I_gold) errors++;
                else oe_errors++;
            end
        end
        // Two reasons, so that a negative control can prove each comparison.
        if (errors != 0) fail("output_mismatch");
        if (oe_errors != 0) fail("output_enable_mismatch");
        // Not vacuous: the fabric itself must show the exact count.
        if (I_top !== FINAL) fail("final_count");
        $display("TB PASS frames=%0d cycles=%0d final_count=%0d", frames, CYCLES, I_top);
        $finish;
    end

    initial begin
        #2_000_000;
        fail("timeout");
    end
endmodule
`default_nettype wire
