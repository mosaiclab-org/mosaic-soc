// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// hw/efpga/mosaic_efpga.sv out of power-up, with a fabric that does what silicon
// may and the netlist benches cannot show. Configuration latches come up at
// random, the routing's loops then oscillate, and no simulator of the netlist
// settles on that, so tb/efpga/run_powerup.sh puts a stand-in in place of the
// fabric: its outputs toggle at random, faster than the clock and unrelated to
// it, and its configuration outputs hold random values until a clear.
//
// Whatever it does, nothing of it may reach the SoC: not the pads, the bus or
// the worker slot, and the loader must clear it. With +tag_match the random
// latches happen to name a design, once in about 2^32: the loader keeps it, as
// it keeps a design through a reset, cut off until firmware removes it.
//
// Plusargs: +seed=<n>  +tag_match  +fault=<control>
// Pass criterion: "TB PASS", printed only after every check below. Every failure
// prints "TB FAIL reason=<r>" and ends with $fatal.
`timescale 1ns / 1ps
`default_nettype none

module tb_efpga_powerup;
    localparam int ROWS = `ROWS;
    localparam int COLS = `COLS;
    localparam int FBPR = `FBPR;
    localparam int MFPC = `MFPC;
    localparam logic [31:0] NO_ANSWER = 32'hFAB0_0BAD;
    localparam logic [15:0] A_TAG = 16'h1234;
    localparam logic [4:0] STATUS = 5'h4, CONTROL = 5'h8, TAG = 5'hC, RESULT = 5'h14;
    localparam logic [31:0] BLOCKED = 32'h10, CUT = 32'h20;

    logic clk = 1'b0, rst_n = 1'b0;
    reg_pkg::reg_req_t reg_req = '0;
    reg_pkg::reg_rsp_t reg_rsp;
    obi_pkg::obi_req_t obi_req = '0;
    obi_pkg::obi_resp_t obi_rsp;
    logic task_wake = 1'b0, task_park = 1'b0;
    wire task_sleep, task_pop;
    wire [31:0] task_data = 32'h0123_1800;
    wire [2*ROWS-1:0] pad_out, pad_oe;
    logic [2*ROWS-1:0] pad_in = '1;
    string fault = "none";
    int clears = 0, pulses = 0;
    logic tag_match = 1'b0;
    logic [31:0] value;

    mosaic_efpga #(
        .ROWS(ROWS),
        .COLS(COLS),
        .FBPR(FBPR),
        .MFPC(MFPC)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .reg_req_i(reg_req),
        .reg_rsp_o(reg_rsp),
        .obi_req_i(obi_req),
        .obi_resp_o(obi_rsp),
        .task_wake_i(task_wake),
        .task_park_i(task_park),
        .task_sleep_o(task_sleep),
        .task_pop_o(task_pop),
        .task_pop_gnt_i(task_pop),
        .task_pop_data_i(task_data),
        .pad_in_i(pad_in),
        .pad_out_o(pad_out),
        .pad_oe_o(pad_oe)
    );

    always #5 clk = ~clk;
    always @(posedge dut.CLK) if (rst_n) pulses++;
    always @(negedge clk) if (&dut.FrameSelect && dut.FrameData === '0) clears++;

    task automatic fail(input string reason);
        $display("TB FAIL reason=%0s t=%0t", reason, $time);
        $fatal(1, "TB FAIL");
    endtask

    // Every cycle, from before the reset ends: cut off, nothing goes out.
    always @(negedge clk) begin
        if (pad_out !== '0 || pad_oe !== '0) fail("pads_driven_while_cut_off");
        if (dut.RAM2FAB_D_I !== '0 || dut.O_top !== '0) fail("inputs_driven_while_cut_off");
        if (rst_n && (obi_rsp.rvalid !== 1'b0 && obi_rsp.rvalid !== 1'b1)) fail("bus_response_unknown");
    end

    task automatic reg_access(input logic write, input logic [4:0] addr, input logic [31:0] wdata);
        reg_req.valid = 1'b1;
        reg_req.write = write;
        reg_req.wstrb = '1;
        reg_req.addr = 32'(addr);
        reg_req.wdata = wdata;
        #1 value = reg_rsp.rdata;
        @(negedge clk);
        reg_req = '0;
    endtask

    task automatic expect_reg(input logic [4:0] addr, input logic [31:0] want, input string reason);
        reg_access(1'b0, addr, '0);
        if (value !== want) begin
            $display("register %h = %h, expected %h", addr, value, want);
            fail(reason);
        end
    endtask

    task automatic expect_no_answer;
        obi_req.req = 1'b1;
        obi_req.addr = 32'h0;
        @(negedge clk);
        obi_req = '0;
        repeat (4) begin
            if (obi_rsp.rvalid === 1'b1) break;
            @(negedge clk);
        end
        if (obi_rsp.rvalid !== 1'b1) fail("bus_not_answered");
        if (obi_rsp.rdata !== NO_ANSWER) fail("fabric_reached_the_bus");
    endtask

    initial begin
        void'($value$plusargs("fault=%s", fault));
        tag_match = $test$plusargs("tag_match");
        if (fault == "fab_en_stuck") force dut.fab_en = 1'b1;
        if (fault == "no_clear") force dut.strobe_q = '0;
        if (tag_match) begin
            force dut.tag = A_TAG;
            force dut.A_config_C = 16'(~A_TAG);
            force dut.B_config_C = 16'(~A_TAG);
        end
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (8) @(negedge clk);

        if (tag_match) begin
            if (clears != 0 || pulses != 0) fail("a_named_design_was_cleared");
            expect_reg(STATUS, 32'h0, "status_after_power_up");
            expect_reg(TAG, 32'(A_TAG), "a_named_design_not_kept");
            release dut.tag;
            release dut.A_config_C;
            release dut.B_config_C;
        end else begin
            if (clears != 1) fail("no_clear_after_power_up");
            if (pulses != 1) fail("no_clock_pulse_after_the_clear");
            expect_reg(STATUS, 32'h0, "status_after_power_up");
            expect_reg(TAG, 32'h0, "latches_not_cleared");
        end

        // Whatever the fabric says, the bus is answered by the hard part.
        expect_no_answer();
        expect_reg(STATUS, BLOCKED, "blocked_not_set");
        reg_access(1'b1, STATUS, BLOCKED);

        // Nothing is configured: CONTROL alone connects nothing.
        reg_access(1'b1, CONTROL, 32'h0);
        expect_no_answer();
        reg_access(1'b1, STATUS, BLOCKED);

        // A task given to the slot ends cut, and the fabric never answered it.
        task_wake = 1'b1;
        @(negedge clk);
        task_wake = 1'b0;
        repeat (4) @(negedge clk);
        if (task_sleep !== 1'b1) fail("slot_awake_after_a_cut");
        expect_reg(RESULT, NO_ANSWER, "fabric_reached_the_result");
        expect_reg(STATUS, CUT, "cut_not_set");

        repeat (200) @(negedge clk);  // the checks above go on running against the noise
        $display("TB PASS seed=%0d tag_match=%0d clears=%0d pulses=%0d", tb_efpga_powerup.dut.eFPGA_inst.seed,
                 tag_match, clears, pulses);
        $finish;
    end

    initial begin
        #1_000_000;
        fail("timeout");
    end
endmodule
`default_nettype wire
