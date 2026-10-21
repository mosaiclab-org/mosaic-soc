// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// mosaic_efpga: a FABulous fabric as a bus peripheral of mosaic_soc (soc.efpga).
//
// The module has a hard part, which always answers, and the fabric core
// `eFPGA`, which is whatever the bitstream makes it. FABulous's eFPGA_top and
// its configuration logic are not used. docs/efpga.md is the reference.
//
// Register port (six registers, never an error; a write that does not carry
// all four bytes is dropped):
//   0x0 BITSTREAM  W   the next word of a stream: <design>.hex or
//                      <design>.unload.hex of util/mosaic_gen/efpga_gen.py
//   0x4 STATUS     R   [0] busy  [1] configured  [2] error
//                      [3] timeout: the user design did not answer   (W1C)
//                      [4] blocked: an access while isolated         (W1C)
//                      [5] cut: a task ended without the design's task_done
//                          (cut off, or parked by the TDU)             (W1C)
//                      [10:8] cause of the error (cause_e)
//   0x8 CONTROL    RW  [0] isolate (reset 1)  [1] user reset (reset 1)
//                      W [2] clear: forget the configuration and start again
//   0xC TAG        R   [15:0] the tag of the design in the latches, 0: none
//   0x10 TASK      R   the descriptor of the last task taken from the TDU
//   0x14 RESULT    R   the design's task_result for it, NoAnswer if it was cut
//
// A stream starts with the sync word. Each frame (a header, then a data word
// per row) is followed by a check word, and the end word by the CRC: each is
// the CRC-32 (zlib) of the words from the sync word on, check words left out.
// A frame goes into the latches only after its check word matched.
//
// Loading. After `clear` the loader writes 0 to every configuration latch and
// then gives the fabric one clock pulse. With no configuration every logic
// cell is enabled and computes 0, so the pulse puts every flip-flop of the
// fabric at 0: the order in which efpga_gen.py sends the frames relies on it.
// The loader then takes the words written to BITSTREAM, drives FrameData and
// FrameStrobe one frame at a time, and sets `configured` only after a frame
// on every strobe line, the end word, a matching CRC and a tag (`has_tag`).
// Anything else sets `error`, and the loader clears the fabric again before it
// reports it.
//
// The tag. A design names itself in 16 configuration latches that drive
// nothing in the fabric (Config_accessC), and holds the complement of that
// tag twice in 32 others (A_config_C, B_config_C). Like the rest of the
// configuration they hold through a reset. `has_tag`: the tag is not 0 and
// both copies match, which latches at random do once in about 2^32.
//
// Unloading. Clearing a design that has run can oscillate. While a design is
// in the latches the loader takes a stream as its unload: the sync word cuts
// the fabric off, and the next word must carry the design's tag (UnloadWord).
// Its frames switch every cell to its flip-flop and every LUT to 0; one clock
// pulse then puts every flip-flop of the logic cells at 0, and the loader
// clears. A refused
// unload leaves the design in the latches, cut off, with the frames before
// the refused one written; its unload can be sent again. Out of reset, a
// fabric for which `has_tag` holds is kept that way; any other is cleared.
//
// Isolation. The fabric is connected only while `configured` is set and
// `isolate` is clear. Otherwise its clock is stopped, but for the one pulse
// of a clear or of an unload, every input is 0 (the user reset, active low,
// among them) and every output is ignored.
//
// Worker slot. The fabric is the last slot of the TDU (EFPGA_TDU_SLOT): a
// descriptor pushed with that core_hint wakes the slot, which then takes the
// head of the TDU's queue, as a woken hart reads TASK_POP, if the head is for
// the slot; a pop of 0 (an empty queue, or a head for a hart) puts it back to
// sleep. The design gets task_valid and the
// descriptor's task_id, under the four-phase handshake of the bus below, and
// its task_done ends the task: the slot keeps task_result in RESULT and goes
// back to sleep, which the TDU sees in CORE_STATUS. A task taken while the
// fabric is cut off, cut off while it runs, or parked by the TDU (PARK_REQ)
// ends at once with `cut` and NoAnswer. task_valid then falls before
// task_done, which withdraws the task: the design must drop it, since a
// task_done it raises later would end the next task. A design that cannot
// drop a task needs its user reset after a cut.
//
// User window. MOSAIC's OBI response has no error signal, so the hard part
// answers every request itself: with NoAnswer (0xFAB0_0BAD) when the fabric is
// cut off, at the request or while it is open (`blocked`), or when the user
// design does not acknowledge within BUS_TIMEOUT cycles (`timeout`). Every
// signal of the window crosses a flop here, to the fabric and back; the pads
// pass through a gate only.
//
// The user design sees, on the east edge (RAM_IO tiles, 16 inputs and 28
// outputs per row; row g = 0 is the tile at Y<ROWS>):
//   RAM2FAB_D_I[16g   +: 8]  wdata[8g +: 8]
//   RAM2FAB_D_I[16g+8 +: 8]  ctl[8g +: 8], ctl = {addr[9:2], be, rst_n, we, valid}
//   FAB2RAM_D_O[16g   +: 8]  rdata[8g +: 8]
//   FAB2RAM_C_O[0]           ack
// with ctl[15] task_valid and ctl[31:16] task_id, and for g < 4
//   FAB2RAM_D_O[16g+8 +: 8]  task_result[8g +: 8]
//   FAB2RAM_C_O[1]           task_done
// Four-phase handshake: valid stays high, with addr, we, be and wdata stable,
// until ack is seen high; ack must then fall before the next request starts.
// A design acts once, when it raises ack, and never raises ack while valid is
// low. A request that ends by `timeout` or by a cut-off may still have
// reached the design.

module mosaic_efpga #(
    // The geometry of the fabric preset, from the manifest of efpga_gen.py.
    parameter int unsigned ROWS = 4,  // rows that hold configuration: Y1..Y<ROWS>
    parameter int unsigned COLS = 4,
    parameter int unsigned FBPR = 32,  // frame bits per row
    parameter int unsigned MFPC = 20,  // frames, that is strobe lines, per column
    parameter int unsigned BUS_TIMEOUT = 256,  // cycles a user design has to answer
    parameter int unsigned LOAD_TIMEOUT = 65536  // cycles between two bitstream words
) (
    input logic clk_i,
    input logic rst_ni,

    input  reg_pkg::reg_req_t reg_req_i,
    output reg_pkg::reg_rsp_t reg_rsp_o,

    input  obi_pkg::obi_req_t  obi_req_i,
    output obi_pkg::obi_resp_t obi_resp_o,

    // The slot of the TDU: its wake and park pulses, whether it sleeps, and
    // the TDU's pop for a worker that is not a hart. Tied off without a TDU.
    input  logic        task_wake_i,
    input  logic        task_park_i,
    output logic        task_sleep_o,
    output logic        task_pop_o,
    input  logic        task_pop_gnt_i,
    input  logic [31:0] task_pop_data_i,

    // The pads of the west edge, two per row. pad_oe_o is 0 while isolated.
    // Connected, a pad the design does not bind is not released: its enable
    // follows whatever the fabric routes there by default (docs/efpga.md).
    input  logic [2*ROWS-1:0] pad_in_i,
    output logic [2*ROWS-1:0] pad_out_o,
    output logic [2*ROWS-1:0] pad_oe_o
);
  localparam logic [31:0] SyncWord = 32'hFAB0_FAB1;  // bit_gen's, as FABulous's ConfigFSM
  localparam logic [31:0] UnloadWord = 32'hFAB2_0000;  // | the tag of the design to remove
  localparam int unsigned EndBit = 20;  // header bit that ends the bitstream
  localparam int unsigned ColLsb = 27;  // column of a frame: header[31:27]
  localparam logic [31:0] NoAnswer = 32'hFAB0_0BAD;
  localparam int unsigned RowW = $clog2(ROWS + 1);
  localparam int unsigned WdogW = $clog2(LOAD_TIMEOUT);
  localparam int unsigned CntW = $clog2(BUS_TIMEOUT);

  if (ROWS < 4 || COLS > 32 || FBPR != 32 || MFPC > EndBit || BUS_TIMEOUT < 3 ||
      LOAD_TIMEOUT < 2) begin : gen_unsupported
    $fatal(1, "mosaic_efpga: this geometry or timeout is not supported");
  end

  typedef enum logic [2:0] {
    CAUSE_NONE,
    CAUSE_COLUMN,    // a frame header names a column the fabric does not have
    CAUSE_COVERAGE,  // the end word came before every strobe line had a frame
    CAUSE_CRC,
    CAUSE_WATCHDOG,  // LOAD_TIMEOUT cycles without a word, once one was written
    CAUSE_TAG        // a stream that is not the unload of the design in the latches,
                     // or a design without a tag and its check
  } cause_e;

  typedef enum logic [3:0] {
    L_CLR0,    // FrameData = 0
    L_CLR1,    // every strobe line high: every latch takes 0
    L_CLR2,
    L_CLR3,    // one clock pulse; then idle, or the error that asked for the clear
    L_IDLE,    // no word yet
    L_SYNC,
    L_TAG,     // an unload: the word after the sync word
    L_HDR,
    L_DATA,
    L_CHECK,
    L_STROBE,
    L_HOLD,    // the strobes of one column are high
    L_CRC,
    L_FLUSH,   // an unload was taken: one clock pulse, then the clear
    L_DONE,    // a design is in the latches
    L_ERROR
  } load_e;

  // CRC-32 as zlib computes it over the words of a stream: a word is four bytes,
  // most significant first, and each byte goes in least significant bit first.
  function automatic logic [31:0] crc32_word(input logic [31:0] crc, input logic [31:0] w);
    logic [31:0] c;
    c = crc;
    for (int unsigned i = 0; i < 32; i++) begin
      c = (c >> 1) ^ ((c[0] ^ w[8*(3-i/8)+i%8]) ? 32'hEDB8_8320 : 32'h0);
    end
    return c;
  endfunction

  // ---------------------------------------------------------------- the fabric
  // The names are those of the port map of FABulous's eFPGA_top.v, which
  // efpga_inst.vh is: efpga_gen.py cuts the instance from the generated file.
  logic CLK;
  logic [FBPR*(ROWS+2)-1:0] FrameData;
  logic [MFPC*COLS-1:0] FrameSelect;
  logic [2*ROWS-1:0] O_top, I_top, T_top;
  logic [16*ROWS-1:0] RAM2FAB_D_I;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [16*ROWS-1:0] FAB2RAM_D_O;
  logic [4*ROWS-1:0] A_config_C, B_config_C, Config_accessC, FAB2RAM_C_O;
  logic [8*ROWS-1:0] FAB2RAM_A_O;
  /* verilator lint_on UNUSEDSIGNAL */

  `include "efpga_inst.vh"

  // -------------------------------------------------------- registers and loader
  load_e load_q, give_up;
  cause_e cause_q;
  // `configured` is a flop of its own, not a decode of load_q: with `isolate`
  // it gates everything that touches the fabric, and a decode of several state
  // bits could glitch while the loader steps.
  logic configured_q, isolate_q, user_rst_q, timeout_q, blocked_q, cut_q;
  logic out_of_reset_q;  // one clock edge has passed since the reset
  logic unload_q;  // the stream being taken removes the design in the latches
  logic [15:0] tag;
  logic has_tag;
  assign tag = Config_accessC[15:0];
  assign has_tag = tag != '0 && A_config_C[15:0] == ~tag && B_config_C[15:0] == ~tag;
  logic [FBPR*(ROWS+2)-1:0] frame_data_q;
  logic [MFPC*COLS-1:0] strobe_q, strobed_q, frame_strobe;
  logic [4:0] col_q;
  logic [MFPC-1:0] mask_q;
  logic [RowW-1:0] row_q;
  logic [31:0] crc_q;
  logic [WdogW-1:0] wdog_q;
  logic set_timeout, set_blocked, set_cut;
  logic [31:0] task_q, result_q;

  logic reg_wr, bs_ready, bs_word, sync, clear, flush, tag_ok, frame_ok;
  logic [ 2:0] reg_idx;  // 0 BITSTREAM, 1 STATUS, 2 CONTROL, 3 TAG, 4 TASK, 5 RESULT
  logic [31:0] wdata;
  assign wdata   = reg_req_i.wdata;
  assign reg_idx = reg_req_i.addr[4:2];
  assign reg_wr  = reg_req_i.valid & reg_req_i.write & (&reg_req_i.wstrb);
  // The loader takes no word while it clears the latches or strobes a frame.
  // `loading`: it waits for the next word of a stream, or for the sync word
  // after a word that was not one.
  logic stepping, loading, busy, fab_en;
  assign stepping = load_q == L_CLR0 || load_q == L_CLR1 || load_q == L_CLR2 ||
      load_q == L_CLR3 || load_q == L_STROBE || load_q == L_HOLD || load_q == L_FLUSH;
  assign loading = load_q == L_SYNC || load_q == L_TAG || load_q == L_HDR ||
      load_q == L_DATA || load_q == L_CHECK || load_q == L_CRC;
  assign bs_ready = !stepping;
  assign bs_word = reg_wr && reg_idx == 3'd0 && bs_ready;
  assign sync = bs_word && wdata == SyncWord &&
      (load_q == L_IDLE || load_q == L_SYNC || load_q == L_DONE);
  assign clear = reg_wr && reg_idx == 3'd2 && wdata[2];
  assign flush = load_q == L_FLUSH;
  assign tag_ok = wdata == (UnloadWord | 32'(tag));
  assign frame_ok = wdata == ~crc_q;

  // A refused load is cleared; a refused unload leaves the design in place.
  always_comb begin
    if (unload_q) give_up = L_DONE;
    else give_up = L_CLR0;
  end

  assign busy   = stepping | loading;
  assign fab_en = configured_q & ~isolate_q;

  always_comb begin
    reg_rsp_o = '0;
    reg_rsp_o.ready = reg_idx != 3'd0 || !reg_req_i.write || bs_ready;
    unique case (reg_idx)
      3'd1:
      reg_rsp_o.rdata = {
        21'b0,
        cause_q,
        2'b0,
        cut_q,
        blocked_q,
        timeout_q,
        cause_q != CAUSE_NONE && !busy,
        configured_q,
        busy
      };
      3'd2: reg_rsp_o.rdata = {30'b0, user_rst_q, isolate_q};
      3'd3: reg_rsp_o.rdata = {16'b0, tag};
      3'd4: reg_rsp_o.rdata = task_q;
      3'd5: reg_rsp_o.rdata = result_q;
      default: ;
    endcase
  end

  always_comb begin
    frame_strobe = '0;
    frame_strobe[MFPC*col_q+:MFPC] = mask_q;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      load_q <= L_CLR0;
      cause_q <= CAUSE_NONE;
      configured_q <= 1'b0;
      out_of_reset_q <= 1'b0;
      unload_q <= 1'b0;
      isolate_q <= 1'b1;
      user_rst_q <= 1'b1;
      timeout_q <= 1'b0;
      blocked_q <= 1'b0;
      cut_q <= 1'b0;
      strobe_q <= '0;
      strobed_q <= '0;
      col_q <= '0;
      mask_q <= '0;
      row_q <= '0;
      crc_q <= '1;
      wdog_q <= '0;
    end else begin
      out_of_reset_q <= 1'b1;
      if (reg_wr && reg_idx == 3'd1) begin  // write 1 to clear
        if (wdata[3]) timeout_q <= 1'b0;
        if (wdata[4]) blocked_q <= 1'b0;
        if (wdata[5]) cut_q <= 1'b0;
      end
      if (set_timeout) timeout_q <= 1'b1;  // a flag set in the cycle of its clear stays
      if (set_blocked) blocked_q <= 1'b1;
      if (set_cut) cut_q <= 1'b1;
      if (reg_wr && reg_idx == 3'd2) begin
        isolate_q  <= wdata[0];
        user_rst_q <= wdata[1];
      end

      wdog_q <= bs_word ? '0 : wdog_q + 1'b1;
      if (bs_word && load_q != L_CHECK && load_q != L_CRC)
        crc_q <= crc32_word(sync ? '1 : crc_q, wdata);

      unique case (load_q)
        // A clear or a reset can come while strobes are high. They fall
        // first, and FrameData moves a full cycle later.
        // Out of reset, a fabric that names a design keeps it (an unknown
        // one, x in simulation, reads as none). A reset drops the strobes.
        L_CLR0: begin
          strobe_q <= '0;
          if (!out_of_reset_q) begin
            if (has_tag) load_q <= L_DONE;
          end else if (strobe_q == '0) load_q <= L_CLR1;
        end
        L_CLR1: begin
          strobe_q <= '1;
          load_q   <= L_CLR2;
        end
        L_CLR2: begin
          strobe_q <= '0;
          load_q   <= L_CLR3;
        end
        L_CLR3: begin
          if (cause_q == CAUSE_NONE) load_q <= L_IDLE;
          else load_q <= L_ERROR;
        end
        L_IDLE, L_SYNC:
        if (sync) begin
          unload_q <= 1'b0;
          strobed_q <= '0;
          load_q <= L_HDR;
        end else if (bs_word) load_q <= L_SYNC;
        // A word that is not the sync word is dropped. The sync word starts an
        // unload, and the fabric stays cut off from then on.
        L_DONE:
        if (sync) begin
          unload_q <= 1'b1;
          strobed_q <= '0;
          configured_q <= 1'b0;
          cause_q <= CAUSE_NONE;
          load_q <= L_TAG;
        end
        L_TAG:
        if (bs_word) begin
          if (tag_ok) load_q <= L_HDR;
          else begin
            cause_q <= CAUSE_TAG;
            load_q  <= L_DONE;
          end
        end
        L_HDR:
        if (bs_word) begin
          col_q  <= wdata[ColLsb+:5];
          mask_q <= wdata[MFPC-1:0];
          row_q  <= RowW'(ROWS);
          if (wdata[EndBit]) load_q <= L_CRC;
          else if (32'(wdata[ColLsb+:5]) >= COLS) begin
            cause_q <= CAUSE_COLUMN;
            load_q  <= give_up;
          end else load_q <= L_DATA;
        end
        // The first data word of a frame is for row Y<ROWS>, the last for Y1.
        L_DATA:
        if (bs_word) begin
          row_q <= row_q - 1'b1;
          if (row_q == 1) load_q <= L_CHECK;
        end
        L_CHECK:
        if (bs_word) begin
          if (frame_ok) load_q <= L_STROBE;
          else begin
            cause_q <= CAUSE_CRC;
            load_q  <= give_up;
          end
        end
        // FrameData is stable one cycle before the strobes rise and at least
        // one cycle after they fall: the latches are transparent while high.
        L_STROBE: begin
          strobe_q <= frame_strobe;
          strobed_q <= strobed_q | frame_strobe;
          load_q <= L_HOLD;
        end
        L_HOLD: begin
          strobe_q <= '0;
          load_q   <= L_HDR;
        end
        L_CRC:
        if (bs_word) begin
          load_q <= give_up;
          if (wdata != ~crc_q) cause_q <= CAUSE_CRC;
          else if (!(&strobed_q)) cause_q <= CAUSE_COVERAGE;
          else if (unload_q) begin  // STATUS and CONTROL as after a clear
            load_q <= L_FLUSH;
            isolate_q <= 1'b1;
            user_rst_q <= 1'b1;
            timeout_q <= 1'b0;
            blocked_q <= 1'b0;
            cut_q <= 1'b0;
          end else if (!has_tag) cause_q <= CAUSE_TAG;  // it could not be unloaded
          else begin
            load_q <= L_DONE;
            configured_q <= 1'b1;
          end
        end
        // Every cell is on its flip-flop and every LUT at 0: the pulse puts
        // every flip-flop at 0, and the clear can follow.
        L_FLUSH: begin
          unload_q <= 1'b0;
          load_q   <= L_CLR0;
        end
        default: ;  // L_ERROR: a word is taken and dropped
      endcase

      if (loading && !bs_word && wdog_q == WdogW'(LOAD_TIMEOUT - 1)) begin
        cause_q <= CAUSE_WATCHDOG;
        load_q  <= give_up;
      end

      if (clear) begin
        load_q <= L_CLR0;
        cause_q <= CAUSE_NONE;
        configured_q <= 1'b0;
        unload_q <= 1'b0;
        isolate_q <= 1'b1;
        user_rst_q <= 1'b1;
        timeout_q <= 1'b0;
        blocked_q <= 1'b0;
        cut_q <= 1'b0;
        strobed_q <= '0;
      end
    end
  end

  // FrameData has no reset. A reset drops the strobes at once, and the latches
  // need their data held beyond that: it moves only while the strobes are low.
  always_ff @(posedge clk_i) begin
    if (load_q == L_CLR0 && strobe_q == '0 && out_of_reset_q) frame_data_q <= '0;
    else if (load_q == L_DATA && bs_word) frame_data_q[FBPR*row_q+:FBPR] <= wdata;
  end

  assign FrameData   = frame_data_q;
  assign FrameSelect = strobe_q;

  // ------------------------------------------------------------ the user window
  typedef enum logic [1:0] {
    U_IDLE,
    U_LOW,   // the acknowledge of the previous request has not fallen yet
    U_REQ,
    U_RESP
  } user_e;

  user_e user_q;
  logic u_valid_q, u_we_q, ack_q;
  // The fabric was connected in the cycle before, so ack_q is its acknowledge:
  // one it left high while cut off shows only a cycle after it is connected.
  logic fab_en_q;
  logic [3:0] u_be_q;
  logic [7:0] u_addr_q;
  logic [31:0] u_wdata_q, rdata_q, resp_q;
  logic [CntW-1:0] u_cnt_q;
  logic [8*ROWS-1:0] wdata_x, ctl_x, rdata_x;

  logic u_expired;
  assign u_expired = u_cnt_q == CntW'(BUS_TIMEOUT - 1);

  assign obi_resp_o.gnt = obi_req_i.req && user_q == U_IDLE;
  assign obi_resp_o.rvalid = user_q == U_RESP;
  assign obi_resp_o.rdata = resp_q;

  always_comb begin
    set_timeout = 1'b0;
    set_blocked = 1'b0;
    unique case (user_q)
      U_IDLE:  set_blocked = obi_req_i.req && !fab_en;
      U_LOW: begin
        set_timeout = u_expired;
        set_blocked = !u_expired && !fab_en;
      end
      U_REQ: begin
        set_timeout = !ack_q && u_expired;
        set_blocked = !ack_q && !u_expired && !fab_en;
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      user_q <= U_IDLE;
      u_valid_q <= 1'b0;
      u_we_q <= 1'b0;
      u_be_q <= '0;
      u_addr_q <= '0;
      u_wdata_q <= '0;
      ack_q <= 1'b0;
      fab_en_q <= 1'b0;
      rdata_q <= '0;
      resp_q <= '0;
      u_cnt_q <= '0;
    end else begin
      ack_q <= fab_en & FAB2RAM_C_O[0];
      fab_en_q <= fab_en;
      rdata_q <= rdata_x[31:0];
      u_cnt_q <= u_cnt_q + 1'b1;
      unique case (user_q)
        U_IDLE:
        if (obi_req_i.req) begin
          u_cnt_q <= '0;
          resp_q  <= NoAnswer;
          if (!fab_en) user_q <= U_RESP;
          else begin
            u_we_q <= obi_req_i.we;
            u_be_q <= obi_req_i.be;
            u_addr_q <= obi_req_i.addr[9:2];
            u_wdata_q <= obi_req_i.wdata;
            u_valid_q <= !ack_q && fab_en_q;
            if (ack_q || !fab_en_q) user_q <= U_LOW;
            else user_q <= U_REQ;
          end
        end
        // The timeout first: the design then never sees this request. A
        // request does not outlive the connection it was granted on.
        U_LOW:
        if (u_expired || !fab_en) user_q <= U_RESP;
        else if (!ack_q) begin
          u_valid_q <= 1'b1;
          user_q <= U_REQ;
        end
        U_REQ:
        if (ack_q || u_expired || !fab_en) begin
          if (ack_q) resp_q <= rdata_q;
          u_valid_q <= 1'b0;
          user_q <= U_RESP;
        end
        default: user_q <= U_IDLE;  // U_RESP
      endcase
    end
  end

  // ----------------------------------------------------------- the worker slot
  typedef enum logic [1:0] {
    T_SLEEP,
    T_POP,   // woken: the slot takes the head of the TDU's queue
    T_LOW,   // the task_done of the previous task has not fallen yet
    T_RUN
  } task_e;

  task_e t_state_q;
  logic t_valid_q, done_q;
  logic [31:0] t_result_q;
  logic [8*ROWS-1:0] result_x;

  assign task_sleep_o = t_state_q == T_SLEEP;
  assign task_pop_o = t_state_q == T_POP;

  // A task taken from the queue that does not end with task_done is cut.
  always_comb begin
    set_cut = 1'b0;
    unique case (t_state_q)
      T_POP: set_cut = task_pop_gnt_i && task_pop_data_i != '0 && (task_park_i || !fab_en);
      T_LOW: set_cut = task_park_i || !fab_en;
      T_RUN: set_cut = !done_q && (task_park_i || !fab_en);
      default: ;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      t_state_q <= T_SLEEP;
      t_valid_q <= 1'b0;
      done_q <= 1'b0;
      t_result_q <= '0;
      task_q <= '0;
      result_q <= '0;
    end else begin
      done_q <= fab_en & FAB2RAM_C_O[1];
      t_result_q <= result_x[31:0];
      unique case (t_state_q)
        T_SLEEP: if (task_wake_i) t_state_q <= T_POP;
        // As with the bus, a task taken in the first cycle after the fabric
        // was connected waits a cycle: task_done may be left high from before.
        T_POP:
        if (task_pop_gnt_i) begin
          if (task_pop_data_i == '0) t_state_q <= T_SLEEP;  // the queue was empty
          else begin
            task_q   <= task_pop_data_i;
            result_q <= NoAnswer;
            if (set_cut) t_state_q <= T_SLEEP;
            else if (done_q || !fab_en_q) t_state_q <= T_LOW;
            else begin
              t_valid_q <= 1'b1;
              t_state_q <= T_RUN;
            end
          end
        end else if (task_park_i) t_state_q <= T_SLEEP;
        T_LOW:
        if (set_cut) t_state_q <= T_SLEEP;
        else if (!done_q) begin
          t_valid_q <= 1'b1;
          t_state_q <= T_RUN;
        end
        default:  // T_RUN
        if (done_q || set_cut) begin
          if (done_q) result_q <= t_result_q;
          t_valid_q <= 1'b0;
          t_state_q <= T_SLEEP;
        end
      endcase
    end
  end

  // ------------------------------------------------------------------ isolation
  tc_clk_gating fabric_clk_gate_i (
      .clk_i,
      .en_i(fab_en || load_q == L_CLR3 || flush),
      .test_en_i(1'b0),
      .clk_o(CLK)
  );

  assign wdata_x = (8 * ROWS)'(u_wdata_q);
  assign ctl_x   = (8 * ROWS)'({task_q[31:16], t_valid_q, u_addr_q, u_be_q, ~user_rst_q, u_we_q,
                                 u_valid_q});
  for (genvar g = 0; g < ROWS; g++) begin : gen_east_edge
    assign RAM2FAB_D_I[16*g+:16] = fab_en ? {ctl_x[8*g+:8], wdata_x[8*g+:8]} : '0;
    assign rdata_x[8*g+:8] = FAB2RAM_D_O[16*g+:8];
    assign result_x[8*g+:8] = FAB2RAM_D_O[16*g+8+:8];
  end

  assign O_top = fab_en ? pad_in_i : '0;
  assign pad_out_o = fab_en ? I_top : '0;
  assign pad_oe_o = fab_en ? T_top : '0;  // T_top is 1 where the design drives its pad
endmodule : mosaic_efpga
