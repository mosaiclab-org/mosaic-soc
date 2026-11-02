// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tb_efpga_block: the hardened block of flow/librelane/scripts/efpga_block.sh, its
// netlist with the wrapper's own loader around the netlist of the fabric, through
// its ports only. Nothing of the wrapper has its name after synthesis, so this
// cannot look inside it as tb_mosaic_efpga.sv does; tb/efpga/run_block.sh runs it.
//
// +design=regs|silent|task loads that design at the module's reset rate, one
// cycle in four, prints every latch, and uses the design: bus_regs through the
// window on each data line, counter8_en on the pads against its RTL, task_count
// as a worker slot. +latches_only stops after the print. +fault=data_stuck and
// +fault=strobe_stuck hold one configuration wire low between two tiles.
//
// Pass criterion: "TB PASS design=<d>". A failure prints "TB FAIL reason=<r>".
`timescale 1ns / 1ps
`default_nettype none

module tb_efpga_block;
    localparam int DIV = 4;  // FABRIC_DIV of hw/efpga/mosaic_efpga.sv
    localparam int BUS_TIMEOUT = 256;
    localparam logic [31:0] R0_RESET = 32'h600D_F00D;
    localparam logic [4:0] BITSTREAM = 5'h0, STATUS = 5'h4, CONTROL = 5'h8, TASK = 5'h10, RESULT = 5'h14;
    localparam logic [31:0] CONFIGURED = 32'h2;
    localparam int COUNT_CYCLES = 300;

    logic clk = 1'b0, rst_n = 1'b1;
    reg_pkg::reg_req_t reg_req = '0;
    reg_pkg::reg_rsp_t reg_rsp;
    obi_pkg::obi_req_t obi_req = '0;
    obi_pkg::obi_resp_t obi_rsp;
    logic [7:0] pad_in = '0;
    wire [7:0] pad_out, pad_oe;
    logic task_wake = 1'b0;
    wire task_sleep, task_pop;
    logic [31:0] head = '0;
    int pops = 0, head_pops = 0;  // the head stands until the grant after head_pops
    wire [31:0] task_data = task_pop && pops == head_pops ? head : '0;
    always @(posedge clk) if (task_pop) pops <= pops + 1;

    `include "efpga_latches.vh"

    mosaic_efpga dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .reg_req_i(reg_req),
        .reg_rsp_o(reg_rsp),
        .obi_req_i(obi_req),
        .obi_resp_o(obi_rsp),
        .task_wake_i(task_wake),
        .task_park_i(1'b0),
        .task_sleep_o(task_sleep),
        .task_pop_o(task_pop),
        .task_pop_gnt_i(task_pop),
        .task_pop_data_i(task_data),
        .pad_in_i(pad_in),
        .pad_out_o(pad_out),
        .pad_oe_o(pad_oe)
    );

    // The RTL the `silent` stream was compiled from, on the fabric's clock.
    wire [7:0] gold_out, gold_oeb;
    counter8_en gold_i (
        .clk   (dut.eFPGA_inst.UserCLK),
        .io_in (pad_in),
        .io_out(gold_out),
        .io_oeb(gold_oeb)
    );

    always #25 clk = ~clk;

    string which, path, fault = "none";
    logic [31:0] rdata;

    task automatic fail(input string reason);
        $display("TB FAIL reason=%0s t=%0t", reason, $time);
        $fatal(1, "TB FAIL");
    endtask

    task automatic reg_access(input logic write, input logic [4:0] addr, input logic [31:0] wdata,
                              output logic [31:0] value);
        logic done;
        reg_req.valid = 1'b1;
        reg_req.write = write;
        reg_req.wstrb = '1;
        reg_req.addr = 32'h2007_0000 | 32'(addr);
        reg_req.wdata = wdata;
        done = 1'b0;
        for (int i = 0; i < 16 && !done; i++) begin
            #1 done = reg_rsp.ready === 1'b1;
            value = reg_rsp.rdata;
            if (reg_rsp.error !== 1'b0) fail("register_port_error");
            @(negedge clk);
        end
        if (!done) fail("register_port_hang");
        reg_req = '0;
    endtask

    task automatic expect_reg(input logic [4:0] addr, input logic [31:0] want, input string reason);
        reg_access(1'b0, addr, '0, rdata);
        if (rdata !== want) begin
            $display("register %h = %h, expected %h", addr, rdata, want);
            fail(reason);
        end
    endtask

    task automatic set_control(input logic [1:0] value);
        reg_access(1'b1, CONTROL, {30'b0, value}, rdata);
        expect_reg(CONTROL, {30'b0, value}, "control_readback");
    endtask

    task automatic load(input string role);
        int fd, words;
        logic [31:0] word;
        if (!$value$plusargs({role, "=%s"}, path)) fail("stream_plusarg_missing");
        fd = $fopen(path, "r");
        if (fd == 0) fail("cannot_open_stream");
        for (words = 0; $fscanf(fd, "%h", word) == 1; words++) reg_access(1'b1, BITSTREAM, word, rdata);
        $fclose(fd);
        if (words == 0) fail("stream_empty");
        repeat (6) @(negedge clk);
        expect_reg(STATUS, CONFIGURED, "not_configured");
    endtask

    task automatic user_access(input logic we, input logic [9:0] addr, input logic [31:0] wdata);
        logic done;
        obi_req.req = 1'b1;
        obi_req.we = we;
        obi_req.be = '1;
        obi_req.addr = {22'h3C_0000, addr};
        obi_req.wdata = wdata;
        done = 1'b0;
        for (int i = 0; i < 4 && !done; i++) begin
            #1 done = obi_rsp.gnt === 1'b1;
            @(negedge clk);
        end
        if (!done) fail("user_window_no_grant");
        obi_req = '0;
        for (int i = 1; obi_rsp.rvalid !== 1'b1; i++) begin
            if (i > BUS_TIMEOUT * DIV + 8) fail("user_window_hang");
            @(negedge clk);
        end
        rdata = obi_rsp.rdata;
        @(negedge clk);
        repeat (DIV) @(negedge clk);  // the design's `valid` has left the edge
    endtask

    task automatic user_reset;
        set_control(2'b10);  // connected, the user reset held
        repeat (4 * DIV) @(negedge clk);
        set_control(2'b00);
    endtask

    task automatic run_regs;
        user_reset();
        user_access(1'b0, 10'h0, '0);
        if (rdata !== R0_RESET) fail("reset_value");
        for (int b = 0; b <= 32; b++) begin  // every data line, each way
            user_access(1'b1, 10'h0, b == 32 ? '0 : 32'h1 << b);
            user_access(1'b0, 10'h0, '0);
            if (rdata !== (b == 32 ? '0 : 32'h1 << b)) fail("readback");
            user_access(1'b1, 10'h0, ~(32'h1 << b));
            user_access(1'b0, 10'h0, '0);
            if (rdata !== ~(32'h1 << b)) fail("readback");
        end
        expect_reg(STATUS, CONFIGURED, "unexpected_timeout");
    endtask

    task automatic run_silent;
        set_control(2'b00);
        pad_in = 8'd3;
        repeat (3 * DIV) @(negedge clk);
        for (int c = DIV; c < (COUNT_CYCLES + 1) * DIV; c++) begin
            int k;
            k = c / DIV;  // a clock of the fabric
            pad_in[7:2] = k[5:0];  // the counter reads only the two pads below
            pad_in[1] = !(k >= 100 && k < 110);
            pad_in[0] = (k == 200);
            @(negedge clk);
            if (pad_out !== gold_out || pad_oe !== ~gold_oeb) begin
                $display("cycle %0d: pads %h/%h, expected %h/%h", k, pad_out, pad_oe, gold_out, ~gold_oeb);
                fail("pad_mismatch");
            end
        end
    endtask

    task automatic run_task(input logic [15:0] id);
        user_reset();
        head = {id, 16'h1800};
        head_pops = pops;
        task_wake = 1'b1;
        @(negedge clk);
        task_wake = 1'b0;
        if (task_sleep !== 1'b0) fail("slot_asleep_with_a_task");
        for (int i = 0; i < 20 * DIV && task_sleep !== 1'b1; i++) @(negedge clk);
        if (task_sleep !== 1'b1) fail("task_not_ended");
        if (pops != head_pops + 1) fail("head_not_taken");
        expect_reg(TASK, head, "task_descriptor");
        expect_reg(RESULT, {16'd1, id ^ 16'hA5A5}, "task_result");
        expect_reg(STATUS, CONFIGURED, "task_cut");
    endtask

    initial begin
        if (!$value$plusargs("design=%s", which)) fail("design_plusarg_missing");
        if ($value$plusargs("fault=%s", fault)) begin
            if (fault == "data_stuck") force dut.eFPGA_inst.\Tile_X0Y1_FrameData_O[10] = 1'b0;
            if (fault == "strobe_stuck") force dut.eFPGA_inst.\Tile_X2Y2_FrameStrobe_O[5] = 1'b0;
        end
        @(negedge clk);
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        // Out of reset the loader clears a fabric that names no design.
        repeat (6) @(negedge clk);
        expect_reg(STATUS, '0, "status_after_reset");
        load(which);
        $display("LATCHES %b", latches);
        if ($test$plusargs("latches_only")) $finish;
        case (which)
            "regs": run_regs();
            "silent": run_silent();
            "task": run_task(16'h1234);
            default: fail("no_such_design");
        endcase
        $display("TB PASS design=%0s t=%0t", which, $time);
        $finish;
    end
endmodule
`default_nettype wire
