// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// The example of the fabric as a worker of the TDU (docs/efpga.md): a design
// against the shell with the task ports alone. A task ends one cycle after it
// is given, with
//   task_result = {n, task_id ^ 16'hA5A5}
// n the tasks ended since the user reset, this one included; a task whose
// task_id is 16'hFFFF never ends, so that firmware can see the TDU park it.
`default_nettype none
module task_count (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        task_valid,
    input  wire [15:0] task_id,
    output wire        task_done,
    output wire [31:0] task_result
);
    reg        done_q;
    reg [15:0] n;
    wire       ends = task_valid && task_id != 16'hFFFF;

    always @(posedge clk) begin
        if (!rst_n) begin
            done_q <= 1'b0;
            n      <= 16'd0;
        end else begin
            done_q <= ends;  // rises after task_valid, falls after it
            if (ends && !done_q) n <= n + 16'd1;  // once per task
        end
    end

    assign task_done   = done_q;
    assign task_result = {n, task_id ^ 16'hA5A5};
endmodule
`default_nettype wire
