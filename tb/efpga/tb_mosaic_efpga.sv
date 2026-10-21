// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// hw/efpga/mosaic_efpga.sv alone: the bench is the bus master on both ports.
// It loads real bitstreams through the BITSTREAM register, reaches the
// registers of a user design through the user window, and removes designs
// with their unload streams.
//
// +silent_run loads the design that never acknowledges, and unloads it after
// it ran. +task_run loads task_count and gives it tasks as the TDU would, the
// bench in the TDU's place on the worker slot. A run without either loads the design with two registers, keeps it
// through a reset after it ran, and replaces it with the other design and
// back (step 6). Only an unload removes a design that has run: clearing one
// can make the fabric oscillate (docs/efpga.md). A stream that was refused,
// cut short or never connected is cleared many times.
//
// The streams are the .hex files of util/mosaic_gen/efpga_gen.py (one word per
// line, the CRC last) and the faulty ones tb/efpga/run_wrapper.sh derives:
//   +silent=         a design that never acknowledges (counter8_en, on the pads)
//   +regs=           bus_regs, the design with two registers
//   +silent_unload=, +regs_unload=  the streams that remove them
//   +crc_fault=      bus_regs up to a frame with one bit flipped, whose check
//                    word was not recomputed
//   +coverage_fault= one strobe line without a frame, the checks recomputed
//   +coverage_first= the same, another strobe line
//   +column_fault=   a frame for a column the fabric does not have
//   +empty=          the sync word, the end word and the CRC: no frame at all
//   +unload_fault=   the unload of bus_regs up to a frame with one bit flipped
//   +unload_cov=     the unload of bus_regs without its last frame
//   +no_tag=, +bad_check=  bus_regs with the latches of its tag at 0, or those
//                    of its check, the checks recomputed
//   +regs_head=      bus_regs up to the last pass, which holds the tag
//   +task=, +task_unload=  task_count, a design against the shell with the
//                    task ports alone, and the stream that removes it
//   +stray=          one word that is not the sync word
// Negative controls: the runner passes a stream in the wrong role, or one of
//   +no_truncate     send the whole stream where the bench first cuts one short
//   +fault=<name>    force a fault into the design under test (search `fault ==`)
//
// Pass criterion: "TB PASS". Every failure prints "TB FAIL reason=<r>" and
// ends with $fatal; the runner also limits each run's wall time.
`timescale 1ns / 1ps
`default_nettype none

module tb_mosaic_efpga;
    localparam int ROWS = `ROWS;
    localparam int COLS = `COLS;
    localparam int FBPR = `FBPR;
    localparam int MFPC = `MFPC;
    localparam int LOAD_TIMEOUT = 512;  // the module's default is 65536 cycles
    localparam int BUS_TIMEOUT = 256;  // the module's default
    localparam logic [31:0] NO_ANSWER = 32'hFAB0_0BAD;
    localparam logic [31:0] R0_RESET = 32'h600D_F00D;
    localparam logic [3:0] BITSTREAM = 4'h0, STATUS = 4'h4, CONTROL = 4'h8, TAG = 4'hC;
    localparam logic [4:0] TASK = 5'h10, RESULT = 5'h14;
    // STATUS: {cause[10:8], cut, blocked, timeout, error, configured, busy}
    localparam logic [10:0] IDLE = 11'h000, CONFIGURED = 11'h002, TIMEOUT = 11'h008,
                            BLOCKED = 11'h010, CUT = 11'h020;
    localparam logic [10:0] E_COLUMN = 11'h104, E_COVERAGE = 11'h204, E_CRC = 11'h304,
                            E_WATCHDOG = 11'h404, E_TAG = 11'h504;
    localparam int COUNT_CYCLES = 300;

    logic clk = 1'b0, rst_n = 1'b1;
    reg_pkg::reg_req_t reg_req = '0;
    reg_pkg::reg_rsp_t reg_rsp;
    obi_pkg::obi_req_t obi_req = '0;
    obi_pkg::obi_resp_t obi_rsp;
    logic [7:0] pad_in = '0;
    wire [7:0] pad_out, pad_oe;

    // The TDU, as the slot sees it: one descriptor at the head of the queue
    // (0: empty), which the bench sets and the slot's first granted pop
    // takes. A pop is granted at once, unless the bench holds the grant
    // back, as a read of TASK_POP in the same cycle would.
    logic task_wake = 1'b0, task_park = 1'b0, hold_grant = 1'b0;
    wire task_sleep, task_pop, task_gnt;
    wire [31:0] task_data;
    logic [31:0] head = '0;
    int pops = 0, head_pops = 0;  // the head stands until the grant after head_pops
    assign task_gnt = task_pop && !hold_grant;
    assign task_data = task_gnt && pops == head_pops ? head : '0;
    always @(posedge clk) if (task_gnt) pops <= pops + 1;

    mosaic_efpga #(
        .ROWS(ROWS),
        .COLS(COLS),
        .FBPR(FBPR),
        .MFPC(MFPC),
        .BUS_TIMEOUT(BUS_TIMEOUT),
        .LOAD_TIMEOUT(LOAD_TIMEOUT)
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
        .task_pop_gnt_i(task_gnt),
        .task_pop_data_i(task_data),
        .pad_in_i(pad_in),
        .pad_out_o(pad_out),
        .pad_oe_o(pad_oe)
    );

    // Reference for the pads: the RTL the `silent` bitstream was compiled from,
    // on the free clock. The fabric's clock is that clock while it is enabled.
    wire [7:0] gold_out, gold_oeb;
    counter8_en gold_i (
        .clk   (clk),
        .io_in (pad_in),
        .io_out(gold_out),
        .io_oeb(gold_oeb)
    );

    always #5 clk = ~clk;

    string path, fault = "none";
    logic [31:0] rdata, status;
    int latency, words, total, mark, cycle = 0, fabric_edges = 0, clears = 0;
    int frames = 0, flushes = 0;
    int cut_at[4] = '{1, 2, 7, 203};  // words of an unload: after the sync, the tag, before a check, in a frame
    logic [15:0] regs_tag, silent_tag;

    task automatic fail(input string reason);
        $display("TB FAIL reason=%0s t=%0t", reason, $time);
        $fatal(1, "TB FAIL");
    endtask

    always @(posedge clk) cycle++;  // stable at the falling edges the bench waits on
    always @(posedge dut.CLK) fabric_edges++;
    // Every strobe line high with FrameData at 0: every latch takes 0.
    always @(negedge clk) if (&dut.FrameSelect && dut.FrameData === '0) clears++;
    // The strobes of one frame: some strobe lines high, not all.
    always @(negedge clk) if (|dut.FrameSelect && !(&dut.FrameSelect)) frames++;

    // The fabric's clock runs while it is cut off only for the pulse of a
    // clear, after every latch took 0 and the strobes fell, one per clear, and
    // for the pulse of an unload. Not with the control that forces the clock on.
    int pulse_mark = 0;
    always @(posedge dut.CLK)
        if (!dut.fab_en && fault != "clock_leak") begin
            if (|dut.FrameSelect) fail("clear_pulse_while_strobes_high");
            if (dut.flush) flushes++;
            else if (clears == pulse_mark) fail("clear_pulse_before_the_strobes");
            pulse_mark = clears;
        end

    // No frame goes into a fabric that is connected.
    always @(negedge clk)
        if (|dut.FrameSelect && !(&dut.FrameSelect) && dut.fab_en) fail("strobe_while_connected");

    // A reset that does not see the tag the latches hold, or its check. Not
    // forced from the initial block: it has to follow every reset.
    always @(negedge rst_n)
        if (fault == "reset_forgets") begin
            force dut.tag = '0;
            repeat (8) @(negedge clk);
            release dut.tag;
        end else if (fault == "check_forgets") begin
            force dut.A_config_C = '0;
            repeat (8) @(negedge clk);
            release dut.A_config_C;
        end else if (fault == "check_b_forgets") begin
            force dut.B_config_C = '0;
            repeat (8) @(negedge clk);
            release dut.B_config_C;
        end

    // The configuration cells are latches, transparent while their strobe is
    // high: FrameData may not move from the cycle before a strobe rises until
    // the cycle after it fell.
    logic [FBPR*(ROWS+2)-1:0] frame_data_prev = '0;
    logic strobe_prev = 1'b0;
    always @(negedge clk) begin
        if ((strobe_prev || |dut.FrameSelect) && dut.FrameData !== frame_data_prev)
            fail("frame_data_moved_at_a_strobe");
        frame_data_prev <= dut.FrameData;
        strobe_prev <= |dut.FrameSelect;
    end

    // What a design sees on the east edge (the table of docs/efpga.md): per
    // row, a byte of ctl above a byte of wdata, with ctl = {addr[9:2], be,
    // rst_n, we, valid}. Whenever `valid` is high there, the edge shows the
    // request the bench has open, line for line. Not with the two controls
    // that force a line for a check further on.
    logic [16*ROWS-1:0] east_want = '0;
    logic [1:0] control = 2'b11;  // CONTROL as the bench left it
    int east_seen = 0;
    logic east_on = 1'b1;  // set with `fault`; Icarus cannot assign from a string
    always @(negedge clk)
        if (dut.RAM2FAB_D_I[8] && east_on) begin
            east_seen++;
            if (dut.RAM2FAB_D_I !== east_want) fail("east_edge_pins");
        end

    // What a design sees of a task on the east edge: task_valid is ctl[15] and
    // task_id ctl[31:16] (the table of docs/efpga.md). Whenever task_valid is
    // high there, task_id is that of the task the bench gave.
    logic [15:0] task_want = '0;
    int task_seen = 0;
    wire [15:0] edge_id = {dut.RAM2FAB_D_I[16*3+8+:8], dut.RAM2FAB_D_I[16*2+8+:8]};
    always @(negedge clk)
        if (dut.RAM2FAB_D_I[16*1+8+7]) begin
            task_seen++;
            if (edge_id !== task_want) fail("task_id_pins");
        end

    // A task_done left high from before, as the slot samples it. Not forced
    // from a task: Icarus refuses a force in an automatic scope.
    logic done_probe = 1'b0;
    always @(done_probe)
        if (done_probe) force dut.done_q = 1'b1;
        else release dut.done_q;
    // The same at the fabric's output, task_done high and ack low.
    logic done_pin_probe = 1'b0;
    always @(done_pin_probe)
        if (done_pin_probe) force dut.FAB2RAM_C_O = {{(4 * ROWS - 2) {1'b0}}, 2'b10};
        else release dut.FAB2RAM_C_O;

    // ---------------------------------------------------------------- bus master
    // Requests change at the falling edge; a transfer happens at the rising edge
    // at which the request and the combinational ready or grant are both high.
    task automatic reg_access(input logic write, input logic [4:0] addr,
                              input logic [31:0] wdata, output logic [31:0] value);
        logic done;
        reg_req.valid = 1'b1;
        reg_req.write = write;
        reg_req.wstrb = '1;
        reg_req.addr  = 32'h2007_0000 | 32'(addr);
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

    task automatic reg_write(input logic [4:0] addr, input logic [31:0] wdata);
        logic [31:0] ignored;
        reg_access(1'b1, addr, wdata, ignored);
    endtask

    // CONTROL takes the two bits and reads them back.
    task automatic set_control(input logic [1:0] value);
        logic [31:0] readback;
        reg_write(CONTROL, {30'b0, value});
        reg_access(1'b0, CONTROL, '0, readback);
        if (readback !== {30'b0, value}) fail("control_readback");
        control = value;
    endtask

    task automatic expect_status(input logic [10:0] want, input string reason);
        reg_access(1'b0, STATUS, '0, status);
        if (status !== {21'b0, want}) begin
            $display("STATUS = %h, expected %h", status, want);
            fail(reason);
        end
    endtask

    // One request in the user window: rdata, and the cycles from grant to rvalid.
    task automatic user_access(input logic we, input logic [9:0] addr, input logic [31:0] wdata,
                               input logic [3:0] be = '1);
        logic done;
        logic [31:0] ctl;
        ctl = {17'b0, addr[9:2], be, ~control[1], we, 1'b1};
        for (int g = 0; g < 4; g++) east_want[16*g+:16] = {ctl[8*g+:8], wdata[8*g+:8]};
        obi_req.req = 1'b1;
        obi_req.we = we;
        obi_req.be = be;
        obi_req.addr = {22'h3C_0000, addr};
        obi_req.wdata = wdata;
        done = 1'b0;
        for (int i = 0; i < 4 && !done; i++) begin
            #1 done = obi_rsp.gnt === 1'b1;
            @(negedge clk);
        end
        if (!done) fail("user_window_no_grant");
        // One request at a time: a second one is not granted while this one is open.
        #1 if (obi_rsp.gnt !== 1'b0) fail("granted_while_busy");
        obi_req = '0;
        for (latency = 1; obi_rsp.rvalid !== 1'b1; latency++) begin
            if (latency > BUS_TIMEOUT + 8) fail("user_window_hang");
            @(negedge clk);
        end
        rdata = obi_rsp.rdata;
        // With the answer, the design's `valid` is low again.
        if (dut.RAM2FAB_D_I[8] !== 1'b0) fail("valid_held_after_the_answer");
        @(negedge clk);
        if (obi_rsp.rvalid !== 1'b0) fail("rvalid_longer_than_a_cycle");
    endtask

    task automatic user_read(input logic [9:0] addr, input logic [31:0] want,
                             input string reason);
        user_access(1'b0, addr, '0);
        if (rdata !== want) begin
            $display("read %h = %h, expected %h", addr, rdata, want);
            fail(reason);
        end
    endtask

    // A request the hard part must answer itself: at once when isolated, after
    // exactly BUS_TIMEOUT cycles when the design is silent. STATUS must then
    // say which, in a flag that only a 1 in its own bit clears.
    task automatic expect_no_answer(input logic we, input logic [10:0] want,
                                    input string reason);
        user_access(we, 10'h0, 32'h5A5A_5A5A);
        if (rdata !== NO_ANSWER) fail(reason);
        if (latency != (want[4] ? 1 : BUS_TIMEOUT + 1)) fail(reason);
        expect_status(want, reason);
        reg_write(STATUS, want[4] ? 32'hFFFF_FFEF : 32'hFFFF_FFF7);
        expect_status(want, "wrong_flag_cleared");
        reg_write(STATUS, want[4] ? 32'h10 : 32'h08);
        expect_status(want & ~11'h018, "flag_not_cleared");
    endtask

    // A fault that shows only while a stream is being written. Not forced
    // from the task: Icarus refuses a force in an automatic scope.
    logic paused = 1'b0;
    always @(posedge paused) if (fault == "connect_while_loading") force dut.fab_en = 1'b1;
    always @(negedge paused) if (fault == "connect_after_pause") force dut.fab_en = 1'b1;

    // Write a stream to BITSTREAM: at most `limit` words, the last of them
    // with `last_xor`. With `pause`, the writer stops for that many cycles
    // before word 151, a frame header, and the bench looks at the fabric
    // meanwhile.
    task automatic load(input string role, input int limit = 100000, input int pause = 0,
                        input logic [31:0] last_xor = '0);
        int fd, start;
        logic [31:0] word;
        if (!$value$plusargs({role, "=%s"}, path)) fail("stream_plusarg_missing");
        fd = $fopen(path, "r");
        if (fd == 0) fail("cannot_open_stream");
        for (words = 0; words < limit && $fscanf(fd, "%h", word) == 1; words++) begin
            // The sync word has gone in and nothing else: a stream has started.
            if (words == 1) expect_isolated("connected_while_loading");
            if (words == 151 && pause > 0) begin
                start = cycle;
                repeat (3) @(negedge clk);  // the frame before is in the latches
                paused = 1'b1;
                expect_status(11'h001, "status_while_loading");
                expect_isolated("connected_while_loading");
                while (cycle - start < pause) @(negedge clk);
                paused = 1'b0;
            end
            reg_write(BITSTREAM, words == limit - 1 ? word ^ last_xor : word);
        end
        $fclose(fd);
        if (words == 0) fail("stream_empty");
        // A whole stream: the loader strobes its last frame, and clears a
        // stream it refuses before the error shows.
        if (words < limit) repeat (6) @(negedge clk);
    endtask

    // A stream the loader must refuse for one cause and then remove, with
    // `isolate` clear the whole time: the fabric must stay cut off. A stream
    // cut at `limit` words must be given up by the loader itself.
    task automatic expect_refused(input string role, input logic [10:0] want,
                                  input string reason, input int limit = 100000);
        int had, start;
        clear();
        set_control(2'b00);
        had = clears;
        load(role, limit);
        start = cycle;
        if (words == limit) begin
            expect_status(11'h001, "status_while_loading");
            expect_isolated("connected_while_loading");
            // The watchdog fires LOAD_TIMEOUT cycles after the last word of the
            // stream, no other write restarts it, and the clear that follows
            // takes four cycles: the error shows in the cycle after, not before.
            while (cycle - start < LOAD_TIMEOUT + 3)
                if ((cycle - start) % 64 == 0) reg_write(STATUS, '0);
                else @(negedge clk);
            expect_status({want[10:8], 8'h01}, "watchdog_not_on_time");
        end
        expect_status(want, reason);
        if (clears != had + 1) fail("refused_stream_left_in_the_latches");
        if (fabric_edges != 1) fail("refused_stream_not_clocked_out");
        expect_isolated("refused_stream_connects");
        user_access(1'b0, 10'h0, '0);  // `blocked` stays set, for the next clear to drop
        if (rdata !== NO_ANSWER || latency != 1) fail("refused_stream_connects");
        reg_write(BITSTREAM, 32'hFAB0_FAB1);  // a word after a refusal starts nothing
        expect_status(want | BLOCKED, "refused_stream_connects");
    endtask

    // How many words a stream has, and the one at `index`.
    task automatic peek(input string role, input int index, output logic [31:0] word,
                        output int length);
        int fd;
        logic [31:0] w;
        if (!$value$plusargs({role, "=%s"}, path)) fail("stream_plusarg_missing");
        fd = $fopen(path, "r");
        if (fd == 0) fail("cannot_open_stream");
        for (length = 0; $fscanf(fd, "%h", w) == 1; length++) if (length == index) word = w;
        $fclose(fd);
    endtask

    task automatic expect_tag(input logic [15:0] want, input string reason);
        logic [31:0] value;
        reg_access(1'b0, TAG, '0, value);
        if (value !== {16'b0, want}) begin
            $display("TAG = %h, expected %h", value, want);
            fail(reason);
        end
    endtask

    // A design leaves through its unload stream: cut off from the sync word
    // on, one clock pulse after the last frame and before the clear, and then
    // STATUS, CONTROL and TAG as after a clear, the flags dropped.
    task automatic unload(input string role);
        int had_clears, had_flushes;
        logic [31:0] readback;
        had_clears = clears;
        had_flushes = flushes;
        load(role);
        expect_status(IDLE, "unload_not_taken");
        if (flushes != had_flushes + 1) fail("unload_without_flush");
        // Counted from the word after the sync word: the pulse and the clear's.
        if (fabric_edges != 2) fail("unload_clock_pulses");
        if (clears != had_clears + 1) fail("unload_not_cleared");
        expect_tag('0, "tag_after_unload");
        reg_access(1'b0, CONTROL, '0, readback);
        if (readback !== 32'h3) fail("control_after_unload");
        control = 2'b11;
    endtask

    // A reset with a design in the latches: the loader keeps it, cut off, and
    // does not clear. STATUS is as when idle, TAG names the design, CONTROL is
    // as after any reset, and a request is blocked.
    task automatic reset_and_keep(input logic [15:0] want, input string reason);
        int had;
        logic [31:0] readback;
        had = clears;
        @(negedge clk);
        #1 rst_n = 1'b0;
        control = 2'b11;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        repeat (6) @(negedge clk);
        if (clears != had) fail(reason);
        expect_status(IDLE, reason);
        expect_tag(want, reason);
        reg_access(1'b0, CONTROL, '0, readback);
        if (readback !== 32'h3) fail(reason);
        expect_isolated(reason);
        set_control(2'b00);
        expect_no_answer(1'b0, BLOCKED, reason);
    endtask

    // CONTROL[2], from any state: the loader forgets what it had, writes 0 to
    // every latch once, gives the fabric one clock pulse, and STATUS and
    // CONTROL are as after reset.
    int clear_calls = 0;
    task automatic clear;
        int had;
        logic [31:0] readback;
        had = clears;
        fabric_edges = 0;
        // Bit 2 wins over bits 1:0 of the same write, whichever they are.
        reg_write(CONTROL, clear_calls % 2 ? 32'hFFFF_FFFD : 32'hFFFF_FFFC);
        clear_calls++;
        control = 2'b11;
        expect_status(11'h001, "not_busy_while_clearing");
        repeat (6) @(negedge clk);
        expect_status(IDLE, "status_after_clear");
        if (clears != had + 1) fail("clear_without_strobes");
        if (fabric_edges != 1) fail("clear_without_clock_pulse");
        reg_access(1'b0, CONTROL, '0, readback);
        if (readback !== 32'h3) fail("control_after_clear");
    endtask

    // While the bench looks for isolation the fabric drives every pad. Not
    // forced from the task: Icarus refuses a force in an automatic scope.
    logic iso_probe = 1'b0;
    always @(iso_probe)
        if (iso_probe) begin
            force dut.I_top = 8'hFF;
            force dut.T_top = 8'hFF;
        end else begin
            release dut.I_top;
            release dut.T_top;
        end

    // The fabric must be cut off: no clock edge, every input 0, pads released.
    task automatic expect_isolated(input string reason);
        fabric_edges = 0;
        iso_probe = 1'b1;
        pad_in = 8'hFF;
        repeat (20) begin
            @(negedge clk);
            if (pad_out !== '0 || pad_oe !== '0 || dut.RAM2FAB_D_I !== '0 || dut.O_top !== '0 ||
                fabric_edges != 0)
                fail(reason);
        end
        pad_in = '0;
        iso_probe = 1'b0;
    endtask

    // ----------------------------------------------------------- the worker slot
    // Give the slot a task: the descriptor at the head of the queue, then the
    // wake pulse a push with the slot's core_hint makes. The slot is awake
    // from the edge that takes the pulse.
    task automatic give(input logic [31:0] desc);
        head = desc;
        head_pops = pops;
        if (desc != '0) task_want = desc[31:16];
        task_wake = 1'b1;
        @(negedge clk);
        task_wake = 1'b0;
        if (task_sleep !== 1'b0) fail("slot_asleep_with_a_task");
    endtask

    task automatic pulse_park;
        task_park = 1'b1;
        @(negedge clk);
        task_park = 1'b0;
    endtask

    task automatic wait_sleep(input int cycles, input string reason);
        for (int i = 0; i < cycles && task_sleep !== 1'b1; i++) @(negedge clk);
        if (task_sleep !== 1'b1) fail(reason);
    endtask

    task automatic expect_reg(input logic [4:0] addr, input logic [31:0] want,
                              input string reason);
        reg_access(1'b0, addr, '0, rdata);
        if (rdata !== want) begin
            $display("register %h = %h, expected %h", addr, rdata, want);
            fail(reason);
        end
    endtask

    // A task the design ends: taken from the queue, on the east edge until
    // task_done, its result kept, the slot asleep again with task_valid low.
    task automatic run_task(input logic [15:0] id, input logic [31:0] want,
                            input string reason);
        int seen;
        seen = task_seen;
        give({id, 16'h1800});
        wait_sleep(20, reason);
        if (dut.RAM2FAB_D_I[16*1+8+7] !== 1'b0) fail("task_valid_held_after_the_end");
        if (task_seen == seen) fail("task_not_on_the_edge");
        if (pops != head_pops + 1) fail("head_not_taken");
        expect_reg(TASK, {id, 16'h1800}, reason);
        expect_reg(RESULT, want, "task_result");
        expect_status(CONFIGURED, reason);
    endtask

    // A task that ended without the design: `cut`, NoAnswer, the slot asleep,
    // and the flag cleared by a 1 in its own bit only.
    task automatic expect_cut(input logic [31:0] desc, input logic [10:0] status_want,
                              input string reason);
        wait_sleep(4, reason);
        expect_reg(TASK, desc, reason);
        expect_reg(RESULT, NO_ANSWER, reason);
        expect_status(status_want | CUT, reason);
        reg_write(STATUS, 32'hFFFF_FFDF);
        expect_status(status_want | CUT, "wrong_flag_cleared");
        reg_write(STATUS, 32'h20);
        expect_status(status_want, "flag_not_cleared");
    endtask

    initial begin
        void'($value$plusargs("fault=%s", fault));
        east_on = fault != "wdata_pin" && fault != "addr_pin";
        if (fault == "fab_en_stuck") force dut.fab_en = 1'b1;
        if (fault == "clock_leak") force dut.CLK = clk;
        if (fault == "no_clear_pulse") force dut.CLK = 1'b0;
        if (fault == "no_flush") force dut.flush = 1'b0;
        if (fault == "tag_ignored") force dut.tag_ok = 1'b1;
        if (fault == "frame_check_ignored") force dut.frame_ok = 1'b1;
        if (fault == "no_park") force dut.task_park_i = 1'b0;
        if (fault == "cut_ignored") force dut.set_cut = 1'b0;
        if (fault == "task_result_pin") force dut.result_x = '0;
        if (fault == "sleep_stuck") force dut.task_sleep_o = 1'b1;
        peek("silent_unload", 1, rdata, total);
        silent_tag = rdata[15:0];
        peek("regs_unload", 1, rdata, total);
        regs_tag = rdata[15:0];
        #1 rst_n = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        $display("[%0t] step 1", $time);
        // 1. Out of reset the loader clears a fabric that names no design (in
        // Icarus every latch starts at x, in Verilator at 0), then idles.
        repeat (6) @(negedge clk);
        expect_status(IDLE, "status_after_reset");
        if (clears != 1) fail("no_clear_after_reset");
        expect_tag('0, "tag_without_a_design");
        reg_access(1'b0, CONTROL, '0, rdata);
        if (rdata !== 32'h3) fail("control_after_reset");

        $display("[%0t] step 2", $time);
        // 2. Nothing is configured: the fabric is cut off whatever CONTROL says,
        // and a request is answered at once.
        expect_no_answer(1'b0, BLOCKED, "not_blocked");
        expect_isolated("not_isolated_after_reset");
        set_control(2'b00);
        expect_isolated("isolate_bit_alone_connects");
        expect_no_answer(1'b1, BLOCKED, "not_blocked");
        // A flag set in the cycle in which its bit is written stays set: the
        // request and the write are taken at the same clock edge.
        obi_req.req = 1'b1;
        reg_write(STATUS, 32'h10);
        obi_req = '0;
        @(negedge clk);
        expect_status(BLOCKED, "flag_lost_in_the_cycle_of_its_clear");
        expect_tag('0, "tag_without_a_design");  // the fourth offset is not STATUS
        reg_write(STATUS, 32'h10);
        // A write that does not carry all four bytes is dropped, and so is
        // one without `valid` (the last) or to TAG: taken, any of these
        // would clear the loader, which puts CONTROL back at 3.
        for (int strb = 0; strb <= 15; strb++) begin
            reg_req.valid = strb < 15;
            reg_req.write = 1'b1;
            reg_req.wstrb = strb[3:0];
            reg_req.addr  = {28'h2007_000, CONTROL};
            reg_req.wdata = 32'h4;
            @(negedge clk);
        end
        reg_req = '0;
        reg_write(4'hC, 32'h4);
        reg_access(1'b0, CONTROL, '0, rdata);
        if (rdata !== 32'h0) fail("ignored_write_taken");
        set_control(2'b11);
        expect_tag('0, "tag_without_a_design");  // nor CONTROL

        if ($test$plusargs("task_run")) begin
        $display("[%0t] step T", $time);
        // T. task_count as a worker of the TDU. It ends a task one cycle
        // after it is given, with {n, task_id ^ 16'hA5A5}, n the tasks it
        // ended since its user reset; a task with id 16'hFFFF never ends.
        // Without a design a task is taken and cut at once.
        mark = task_seen;
        give(32'h0042_1800);
        expect_cut(32'h0042_1800, IDLE, "task_without_a_design");
        load("task");
        expect_status(CONFIGURED, "task_not_configured");
        set_control(2'b10);
        repeat (4) @(negedge clk);
        set_control(2'b00);
        run_task(16'h1234, {16'd1, 16'h1234 ^ 16'hA5A5}, "first_task");
        run_task(16'hBEEF, {16'd2, 16'hBEEF ^ 16'hA5A5}, "second_task");
        // A wake with the queue empty: the slot takes 0 and sleeps again.
        give('0);
        wait_sleep(4, "empty_pop_kept_awake");
        if (pops != head_pops + 1) fail("empty_pop_not_taken");
        expect_reg(TASK, 32'hBEEF_1800, "empty_pop_changed_task");
        expect_status(CONFIGURED, "empty_pop_cut");
        // A pop not granted waits; parked meanwhile, the slot sleeps with
        // nothing taken. Granted after a new wake, the task runs.
        hold_grant = 1'b1;
        give(32'h5555_1800);
        repeat (10) @(negedge clk);
        if (task_sleep !== 1'b0 || pops != head_pops) fail("pop_not_waiting");
        pulse_park;
        wait_sleep(4, "park_ignored");
        expect_status(CONFIGURED, "park_while_popping_cut");
        hold_grant = 1'b0;
        run_task(16'h5555, {16'd3, 16'h5555 ^ 16'hA5A5}, "task_after_a_held_pop");
        // Parked in the cycle its pop is granted: taken, and cut at once.
        hold_grant = 1'b1;
        mark = task_seen;
        give(32'h0333_1800);
        repeat (4) @(negedge clk);
        hold_grant = 1'b0;
        pulse_park;
        if (pops != head_pops + 1) fail("park_at_the_pop_not_taken");
        expect_cut(32'h0333_1800, CONFIGURED, "park_at_the_pop_ignored");
        if (task_seen != mark) fail("park_at_the_pop_ignored");
        // A task_done still high when a task is taken: the task waits for it
        // to fall before task_valid rises; parked meanwhile, it is cut and
        // never reaches the design.
        done_probe = 1'b1;
        give(32'h0666_1800);
        repeat (10) @(negedge clk);
        if (task_sleep !== 1'b0 || task_seen != mark) fail("task_given_over_a_high_done");
        pulse_park;
        expect_cut(32'h0666_1800, CONFIGURED, "park_ignored_while_waiting");
        if (task_seen != mark) fail("task_given_over_a_high_done");
        // Again, and the done falls: the task runs.
        give(32'h0777_1800);
        repeat (10) @(negedge clk);
        if (task_sleep !== 1'b0 || task_seen != mark) fail("task_given_over_a_high_done");
        done_probe = 1'b0;
        wait_sleep(20, "task_after_a_high_done");
        expect_reg(RESULT, {16'd4, 16'h0777 ^ 16'hA5A5}, "task_after_a_high_done");
        expect_status(CONFIGURED, "task_after_a_high_done");
        // A task the design never ends runs until the TDU parks the slot.
        mark = task_seen;
        give(32'hFFFF_1800);
        repeat (50) @(negedge clk);
        if (task_sleep !== 1'b0 || task_seen < mark + 40) fail("endless_task_not_running");
        pulse_park;
        expect_cut(32'hFFFF_1800, CONFIGURED, "park_ignored");
        if (dut.RAM2FAB_D_I[16*1+8+7] !== 1'b0) fail("task_valid_held_after_the_park");
        // Cut off while it runs, and given while cut off: cut at once.
        give(32'hFFFF_1800);
        repeat (10) @(negedge clk);
        set_control(2'b01);
        expect_cut(32'hFFFF_1800, CONFIGURED, "isolation_did_not_cut");
        mark = task_seen;
        give(32'h0099_1800);
        expect_cut(32'h0099_1800, CONFIGURED, "task_while_isolated");
        if (task_seen != mark) fail("task_reached_an_isolated_fabric");
        expect_isolated("task_reached_an_isolated_fabric");
        // While isolated, a wake with the queue empty takes nothing: no `cut`.
        give('0);
        wait_sleep(4, "empty_pop_kept_awake");
        expect_status(CONFIGURED, "empty_pop_cut_while_isolated");
        // A pop granted in the first cycle after the fabric is connected
        // waits a cycle: a task_done the design left high while cut off
        // shows only then. Connected without the user reset, the count goes
        // on.
        hold_grant = 1'b1;
        give(32'h0ABC_1800);
        done_pin_probe = 1'b1;
        reg_write(CONTROL, 32'h0);
        control = 2'b00;
        hold_grant = 1'b0;
        mark = task_seen;
        repeat (10) @(negedge clk);
        if (task_sleep !== 1'b0 || task_seen != mark) fail("task_given_at_the_connection");
        done_pin_probe = 1'b0;
        wait_sleep(20, "task_after_the_connection");
        expect_reg(RESULT, {16'd5, 16'h0ABC ^ 16'hA5A5}, "task_after_the_connection");
        expect_status(CONFIGURED, "task_after_the_connection");
        run_task(16'h0099, {16'd6, 16'h0099 ^ 16'hA5A5}, "task_after_reconnect");
        // The design has run: its unload removes it, and a task is cut again.
        unload("task_unload");
        give(32'h0042_1800);
        expect_cut(32'h0042_1800, IDLE, "task_after_the_unload");
        $display("TB PASS design=task words=%0d fault=%0s", words, fault);
        $finish;
        end

        if ($test$plusargs("silent_run")) begin
        $display("[%0t] step 3", $time);
        // 3. A design that never acknowledges: the hard part answers for it.
        load("silent");
        expect_status(CONFIGURED, "silent_not_configured");
        expect_isolated("configured_alone_connects");
        expect_no_answer(1'b0, CONFIGURED | BLOCKED, "isolated_design_reached");
        set_control(2'b00);
        expect_no_answer(1'b0, CONFIGURED | TIMEOUT, "silent_design_answered");
        expect_no_answer(1'b1, CONFIGURED | TIMEOUT, "silent_design_answered");

        // The same design drives the pads: it counts, holds, resets (io_in[0]
        // is its reset, io_in[1] its enable), and the hard part passes it on.
        if (fault == "pad_stuck") force dut.I_top[2] = 1'b0;
        pad_in = 8'd3;
        repeat (3) @(negedge clk);
        for (int k = 1; k <= COUNT_CYCLES; k++) begin
            pad_in[7:2] = k[5:0];  // the counter reads only the two pads below
            pad_in[1] = !(k >= 100 && k < 110);
            pad_in[0] = (k == 200);
            @(negedge clk);
            if (dut.O_top !== pad_in) fail("pad_in_not_passed_on");
            if (pad_out !== gold_out || pad_oe !== ~gold_oeb) begin
                $display("cycle %0d: pads %h/%h, expected %h/%h", k, pad_out, pad_oe, gold_out,
                         ~gold_oeb);
                fail("pad_mismatch");
            end
        end
        if (pad_out !== 8'd100) fail("pad_final_count");
        // Connected, each pad passes on what the fabric drives, whatever that is.
        force dut.I_top = 8'hA5;
        force dut.T_top = 8'h3C;
        @(negedge clk);
        if (pad_out !== 8'hA5 || pad_oe !== 8'h3C) fail("pads_not_passed_on");
        force dut.I_top = 8'h5A;
        force dut.T_top = 8'hC3;
        @(negedge clk);
        if (pad_out !== 8'h5A || pad_oe !== 8'hC3) fail("pads_not_passed_on");
        release dut.I_top;
        release dut.T_top;
        // `timeout` too stays set when it is set in the cycle its bit is
        // written: the write is taken at the edge the timeout ends.
        fork
            user_access(1'b0, 10'h0, '0);
            begin
                repeat (BUS_TIMEOUT) @(negedge clk);
                reg_write(STATUS, 32'h08);
            end
        join
        expect_status(CONFIGURED | TIMEOUT, "flag_lost_in_the_cycle_of_its_clear");
        reg_write(STATUS, 32'h08);
        // Cut off in the last cycle of the timeout, the request ends by the
        // timeout; a cycle earlier, by the cut-off.
        for (int early = 1; early <= 2; early++) begin
            fork
                user_access(1'b0, 10'h0, '0);
                begin
                    repeat (BUS_TIMEOUT - early) @(negedge clk);
                    reg_write(CONTROL, 32'h1);
                end
            join
            expect_status(CONFIGURED | (early == 1 ? TIMEOUT : BLOCKED), "cut_off_at_the_timeout");
            reg_write(STATUS, 32'h18);
            set_control(2'b00);
        end
        // `isolate` while a request is open: the design loses every line of it
        // at once, an acknowledge from the fabric is no longer heard, and the
        // hard part ends the request at once, `blocked`.
        fork
            user_access(1'b1, 10'h3FC, '1);
            begin
                repeat (8) @(negedge clk);
                set_control(2'b01);
                force dut.FAB2RAM_C_O[0] = 1'b1;
                expect_isolated("isolate_bit_does_not_isolate");
            end
        join
        release dut.FAB2RAM_C_O[0];
        if (rdata !== NO_ANSWER || latency > 16) fail("isolated_request_not_ended");
        expect_status(CONFIGURED | BLOCKED, "isolated_request_not_ended");
        reg_write(STATUS, 32'h10);
        // Connected again, the design does not see that request.
        set_control(2'b00);
        repeat (8) begin
            @(negedge clk);
            if (dut.RAM2FAB_D_I[8] !== 1'b0) fail("request_after_its_cut_off");
        end
        // The counter has run: its unload removes it.
        expect_tag(silent_tag, "tag_of_the_design");
        unload("silent_unload");
        $display("TB PASS design=silent words=%0d fault=%0s", words, fault);
        $finish;
        end

        $display("[%0t] step 4", $time);
        // 4. Every bit of a frame's check word is compared, before the frame
        // goes into the latches: the first frame of bus_regs is written only
        // when its check word, the seventh word, is right.
        for (int b = 0; b <= 32; b++) begin
            mark = frames;
            load("regs", 7, 0, b == 32 ? 32'h0 : 32'h1 << b);
            repeat (6) @(negedge clk);
            expect_status(b == 32 ? 11'h001 : E_CRC, "check_bit_not_compared");
            if (frames != mark + (b == 32)) fail("check_bit_not_compared");
            clear();
        end
        // Every bit of the CRC word is compared. A stream without a frame is
        // refused for its coverage when the CRC is right, and for its CRC when
        // one bit of that word, the third, is flipped.
        for (int b = 32; b >= 0; b--) begin
            load("empty", 3, 0, b == 32 ? 32'h0 : 32'h1 << b);
            repeat (6) @(negedge clk);
            expect_status(b == 32 ? E_COVERAGE : E_CRC, "crc_bit_not_compared");
            clear();
        end
        // Only the sync word starts the frames: after a word one bit away
        // from it, a frame for a column that is not there is not looked at.
        for (int b = 0; b < 32; b++) begin
            reg_write(BITSTREAM, 32'hFAB0_FAB1 ^ (32'h1 << b));
            reg_write(BITSTREAM, {5'd31, 27'h1});
            expect_status(11'h001, "near_sync_word_taken");
            clear();
        end
        // Every column the fabric does not have is refused, at the header.
        for (int c = COLS; c < 32; c++) begin
            reg_write(BITSTREAM, 32'hFAB0_FAB1);
            reg_write(BITSTREAM, {c[4:0], 27'h1});
            repeat (6) @(negedge clk);
            expect_status(E_COLUMN, "column_not_refused");
            clear();
        end
        // A clear in the cycle the strobes of a frame rise: 25 words end with
        // the last word of a frame of the first pass, which is not empty.
        load("regs", 25);
        clear();
        // A reset while those strobes are high: FrameData holds, and the
        // loader starts again as from power-up.
        load("regs", 25);
        mark = clears;
        @(negedge clk);
        #1 rst_n = 1'b0;
        control = 2'b11;
        #1 if (dut.FrameSelect !== '0) fail("strobes_not_reset");
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        repeat (6) @(negedge clk);
        expect_status(IDLE, "status_after_reset");
        if (clears != mark + 1) fail("no_clear_after_reset");
        // A clear in the middle of a frame, and a word written while the
        // loader clears: it waits, and is then taken.
        load("regs", 101);
        reg_write(CONTROL, 32'h4);
        reg_write(BITSTREAM, 32'hFAB0_FAB1);
        repeat (6) @(negedge clk);
        expect_status(11'h001, "word_lost_while_clearing");
        // Streams the loader must refuse, each for its own cause: the four
        // faulty ones (crc_fault ends with the check word that does not
        // match), then bus_regs cut in the middle of a frame, after its sync
        // word and before its CRC word.
        expect_refused("crc_fault", E_CRC, "crc_fault_accepted");
        peek("regs", 0, rdata, total);
        expect_refused("coverage_fault", E_COVERAGE, "coverage_fault_accepted");
        expect_refused("coverage_first", E_COVERAGE, "coverage_first_accepted");
        expect_refused("column_fault", E_COLUMN, "column_fault_accepted");
        expect_refused("regs", E_WATCHDOG, "truncated_accepted",
                       $test$plusargs("no_truncate") ? 100000 : 202);
        expect_refused("regs", E_WATCHDOG, "truncated_accepted", 1);
        expect_refused("regs", E_WATCHDOG, "truncated_accepted", total - 1);
        expect_refused("stray", E_WATCHDOG, "stray_word_not_given_up", 1);

        $display("[%0t] step 5", $time);
        // 5. The design with two registers, after the refused streams. An idle
        // loader has no watchdog.
        clear();
        repeat (LOAD_TIMEOUT + 8) @(negedge clk);
        expect_status(IDLE, "watchdog_while_idle");
        // Configured and never connected: a request is blocked, and the
        // design can still be cleared and loaded again. A reset keeps it, and
        // its unload removes it.
        load("regs");
        expect_status(CONFIGURED, "regs_not_configured");
        expect_tag(regs_tag, "tag_of_the_design");
        expect_isolated("configured_alone_connects");
        expect_no_answer(1'b0, CONFIGURED | BLOCKED, "isolated_design_reached");
        clear();
        expect_tag('0, "tag_after_clear");
        load("regs");
        reset_and_keep(regs_tag, "warm_reset_cleared");
        unload("regs_unload");
        // A design whose tag is 0, or whose check does not match its tag,
        // could not be kept through a reset: it is refused. So is a stream cut
        // before its last pass, which holds the tag: a reset then clears it.
        expect_refused("no_tag", E_TAG, "untagged_design_accepted");
        expect_refused("bad_check", E_TAG, "unchecked_design_accepted");
        // Its frames all in, its tag set and its check wrong, it is cleared by
        // a reset, as a stream cut before its last pass, without the tag, is.
        clear();
        peek("bad_check", 0, rdata, total);
        load("bad_check", total - 2);
        mark = clears;
        @(negedge clk);
        #1 rst_n = 1'b0;
        control = 2'b11;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        repeat (6) @(negedge clk);
        if (clears != mark + 1) fail("unchecked_tag_kept");
        expect_tag('0, "unchecked_tag_kept");
        // Every latch of the check is compared: bus_regs with any one of them
        // wrong is refused.
        for (int k = 0; k < 32; k++) begin
            clear();
            if (k < 16) force dut.A_config_C = ~regs_tag ^ (16'h1 << k);
            else force dut.B_config_C = ~regs_tag ^ (16'h1 << (k - 16));
            load("regs");
            expect_status(E_TAG, "check_latch_not_compared");
            release dut.A_config_C;
            release dut.B_config_C;
        end
        clear();
        load("regs_head");
        mark = clears;
        @(negedge clk);
        #1 rst_n = 1'b0;
        control = 2'b11;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        repeat (6) @(negedge clk);
        if (clears != mark + 1) fail("partial_load_kept");
        expect_status(IDLE, "partial_load_kept");
        expect_tag('0, "partial_load_kept");
        // Nothing is left of it: a stream without a frame has no coverage.
        load("empty", 3);
        repeat (6) @(negedge clk);
        expect_status(E_COVERAGE, "coverage_kept_across_a_clear");
        clear();
        // Again with `isolate` clear the whole time: nothing reaches the
        // fabric before the CRC matched. A writer whose next word comes
        // LOAD_TIMEOUT cycles after the last is not cut off.
        set_control(2'b00);
        load("regs", 100000, LOAD_TIMEOUT - 1);
        expect_status(CONFIGURED, "regs_not_configured");
        if (dut.RAM2FAB_D_I[8] !== 1'b0) fail("valid_without_a_request");
        if (fault == "wdata_pin") force dut.RAM2FAB_D_I[55] = 1'b0;  // wdata[31]
        set_control(2'b10);  // connected, the user reset held
        repeat (4) @(negedge clk);
        set_control(2'b00);
        user_access(1'b0, 10'h0, '0);
        expect_status(CONFIGURED, "unexpected_timeout");
        if (rdata !== R0_RESET) fail("reset_value");
        user_read(10'h4, {R0_RESET[31:4], 4'h0}, "reset_value");
        if (latency > 8) fail("answer_too_late");
        for (int b = 0; b <= 32; b++) begin  // every data line, each way
            user_access(1'b1, 10'h0, b == 32 ? '0 : 32'h1 << b);
            // The answer to a write carries what the design shows in the cycle
            // it acknowledges: bus_regs has the new value there, not before.
            if (rdata !== (b == 32 ? '0 : 32'h1 << b)) fail("read_data_taken_early");
            user_read(10'h0, b == 32 ? '0 : 32'h1 << b, "readback");
            user_access(1'b1, 10'h0, ~(32'h1 << b));
            user_read(10'h0, ~(32'h1 << b), "readback");
        end
        // Each line of the address and of the byte enables alone: the monitor
        // of the east edge checks these requests as it checked the walks of
        // the data lines above.
        if (fault == "be_pin") force dut.RAM2FAB_D_I[11] = 1'b0;  // be[0]
        mark = east_seen;
        for (int b = 0; b < 12; b++)
            user_access(1'b0, b < 8 ? 10'h4 << b : 10'h0, '0, b < 8 ? 4'h0 : 4'h1 << (b - 8));
        if (east_on && east_seen == mark) fail("east_edge_pins");
        if (fault == "addr_pin") force dut.RAM2FAB_D_I[15] = 1'b0;  // the word address
        user_access(1'b1, 10'h0, 32'hC001_D00D);
        user_access(1'b1, 10'h4, 32'hFFFF_FFF6);  // R1 is four bits wide
        user_read(10'h4, 32'hC001_D006, "address_decode");
        user_read(10'h0, 32'hC001_D00D, "address_decode");
        expect_status(CONFIGURED, "unexpected_timeout");
        // An acknowledge in the cycle the fabric is cut off is the answer:
        // the design acted on the request.
        fork
            user_access(1'b1, 10'h0, 32'h1234_5678);
            begin
                while (dut.FAB2RAM_C_O[0] !== 1'b1) @(negedge clk);
                reg_write(CONTROL, 32'h1);
            end
        join
        if (rdata !== 32'h1234_5678) fail("acknowledge_at_the_cut_off_lost");
        expect_status(CONFIGURED, "acknowledge_at_the_cut_off_lost");
        // An acknowledge left high while the fabric was cut off answers no
        // request granted as it is connected again.
        force dut.FAB2RAM_C_O[0] = 1'b1;
        reg_write(CONTROL, 32'h0);
        control = 2'b00;
        fork
            user_read(10'h4, 32'h1234_5676, "stale_acknowledge_taken");
            begin
                repeat (20) @(negedge clk);
                release dut.FAB2RAM_C_O[0];
            end
        join
        user_access(1'b1, 10'h0, 32'hC001_D00D);

        // An acknowledge that never falls: the next request is not passed on.
        force dut.FAB2RAM_C_O[0] = 1'b1;
        repeat (2) @(negedge clk);
        expect_no_answer(1'b0, CONFIGURED | TIMEOUT, "stuck_acknowledge_answered");
        // Cut off while it waits for that acknowledge to fall, a request ends
        // at once, `blocked`, even when the cut lasts one cycle.
        fork
            user_access(1'b0, 10'h0, '0);
            begin
                repeat (8) @(negedge clk);
                reg_write(CONTROL, 32'h1);
                reg_write(CONTROL, 32'h0);
            end
        join
        if (rdata !== NO_ANSWER || latency > 16) fail("waiting_request_not_cut_off");
        expect_status(CONFIGURED | BLOCKED, "waiting_request_not_cut_off");
        reg_write(STATUS, 32'h10);
        set_control(2'b00);
        // One that falls in the last cycle of the timeout: too late, and the
        // request is not passed on then either.
        fork
            expect_no_answer(1'b0, CONFIGURED | TIMEOUT, "late_acknowledge_fall");
            begin
                repeat (BUS_TIMEOUT - 1) @(negedge clk);
                release dut.FAB2RAM_C_O[0];
            end
        join
        repeat (2) @(negedge clk);
        user_read(10'h0, 32'hC001_D00D, "after_stuck_acknowledge");
        // The timeout runs from the grant: the wait for an old acknowledge to
        // fall is part of it.
        force dut.FAB2RAM_C_O[0] = 1'b1;
        repeat (2) @(negedge clk);
        fork
            expect_no_answer(1'b0, CONFIGURED | TIMEOUT, "timeout_restarted_after_the_wait");
            begin
                repeat (100) @(negedge clk);
                force dut.FAB2RAM_C_O[0] = 1'b0;
            end
        join
        // An acknowledge in the last cycle of the timeout is still an answer.
        fork
            user_access(1'b0, 10'h0, '0);
            begin
                repeat (BUS_TIMEOUT - 1) @(negedge clk);
                force dut.FAB2RAM_C_O[0] = 1'b1;
            end
        join
        release dut.FAB2RAM_C_O[0];
        if (rdata !== 32'hC001_D00D || latency != BUS_TIMEOUT + 1) fail("last_cycle_acknowledge");
        expect_status(CONFIGURED, "last_cycle_acknowledge");
        repeat (4) @(negedge clk);

        // A word written when a design is configured is dropped, unless it is
        // the sync word.
        reg_write(BITSTREAM, 32'hFAB2_0000 | regs_tag);
        expect_status(CONFIGURED, "word_after_configuration");
        // The user reset alone puts the registers back.
        if (fault == "no_user_reset") force dut.RAM2FAB_D_I[10] = 1'b1;  // rst_n
        set_control(2'b10);
        repeat (4) @(negedge clk);
        set_control(2'b00);
        user_read(10'h0, R0_RESET, "user_reset");
        // Isolated, every line of the east edge is 0, whatever the last
        // request left on it.
        user_access(1'b1, 10'h3FC, '1);
        set_control(2'b01);
        expect_isolated("isolate_bit_does_not_isolate");

        $display("[%0t] step 6", $time);
        // 6. bus_regs has run. A reset keeps it, cut off. A load stream and
        // the unload of another design are refused at their second word, and
        // a damaged frame of its own unload at that frame's check word: no
        // frame of the first two is written, and the frames before the
        // damaged one are. The unload then removes it, the counter takes its
        // place, runs and is removed, and bus_regs comes back from its reset.
        reset_and_keep(regs_tag, "reset_cleared_a_design_that_ran");
        reg_write(BITSTREAM, 32'h0);
        expect_status(IDLE, "word_while_kept");
        mark = frames;
        load("regs", 2);
        expect_status(E_TAG, "load_over_a_design");
        load("silent_unload", 2);
        expect_status(E_TAG, "wrong_design_unload_accepted");
        // Every bit of the tag word, the marker included.
        for (int b = 0; b < 32; b++) begin
            reg_write(BITSTREAM, 32'hFAB0_FAB1);
            reg_write(BITSTREAM, (32'hFAB2_0000 | regs_tag) ^ (32'h1 << b));
            expect_status(E_TAG, "tag_bit_not_compared");
        end
        if (frames != mark) fail("refused_stream_written");
        // An unload cut short, after its sync word, its tag word, in front
        // of a check word and in a frame; one with a frame for a column that
        // is not there; one with a wrong CRC, and one without its last
        // frame: each is refused, and the design stays, with no clear.
        mark = clears;
        foreach (cut_at[i]) begin
            load("regs_unload", cut_at[i]);
            repeat (LOAD_TIMEOUT + 8) @(negedge clk);
            expect_status(E_WATCHDOG, "unload_cut_not_given_up");
            expect_tag(regs_tag, "unload_cut_removed_the_design");
        end
        reg_write(BITSTREAM, 32'hFAB0_FAB1);
        reg_write(BITSTREAM, 32'hFAB2_0000 | regs_tag);
        reg_write(BITSTREAM, {5'd31, 27'h1});
        expect_status(E_COLUMN, "unload_column_not_refused");
        peek("regs_unload", 0, rdata, total);
        load("regs_unload", total, 0, 32'h1);
        expect_status(E_CRC, "unload_crc_not_compared");
        load("unload_cov");
        expect_status(E_COVERAGE, "unload_coverage_not_counted");
        if (clears != mark) fail("refused_unload_cleared_the_design");
        expect_tag(regs_tag, "refused_unload_cleared_the_design");
        mark = frames;
        load("unload_fault");
        expect_status(E_CRC, "damaged_unload_accepted");
        if (frames != mark + 40) fail("damaged_unload_frames");
        expect_tag(regs_tag, "damaged_unload_accepted");
        unload("regs_unload");
        // Right after an unload, a stray word is given up and cleared like
        // any other: the loader no longer takes a stream as an unload.
        mark = clears;
        reg_write(BITSTREAM, 32'h0);
        repeat (LOAD_TIMEOUT + 8) @(negedge clk);
        expect_status(E_WATCHDOG, "stray_word_after_an_unload");
        if (clears != mark + 1) fail("stray_word_after_an_unload");
        clear();
        load("silent");
        expect_status(CONFIGURED, "replacement_not_configured");
        expect_tag(silent_tag, "tag_of_the_design");
        set_control(2'b00);
        expect_no_answer(1'b0, CONFIGURED | TIMEOUT, "silent_design_answered");
        pad_in = 8'd2;  // enabled, not reset: the count from 0
        repeat (50) @(negedge clk);
        if (pad_out !== 8'd50) fail("replacement_not_running");
        // A request open when the unload's sync word cuts the design off is
        // answered at once, and the unload drops the `blocked` it sets and the
        // `timeout` the request before it left.
        user_access(1'b0, 10'h0, '0);
        fork
            user_access(1'b0, 10'h0, '0);
            begin
                repeat (8) @(negedge clk);
                unload("silent_unload");
            end
        join
        if (rdata !== NO_ANSWER || latency > 16) fail("request_outlived_the_design");
        pad_in = '0;
        // Right after an unload, which strobed every line, a load without a
        // frame is refused for its coverage.
        load("coverage_fault");
        expect_status(E_COVERAGE, "coverage_after_an_unload");
        clear();
        // bus_regs again: every flip-flop is at 0 before its user reset.
        load("regs");
        set_control(2'b00);
        user_read(10'h0, '0, "reload_not_from_zero");
        set_control(2'b10);
        repeat (4) @(negedge clk);
        set_control(2'b00);
        user_read(10'h0, R0_RESET, "reload_reset_value");
        user_access(1'b1, 10'h0, 32'h1234_5678);
        user_read(10'h0, 32'h1234_5678, "reload_readback");
        expect_status(CONFIGURED, "unexpected_timeout");

        $display("TB PASS design=regs words=%0d fault=%0s", words, fault);
        $finish;
    end

    initial begin
        #5_000_000;
        fail("timeout");
    end
endmodule
`default_nettype wire
