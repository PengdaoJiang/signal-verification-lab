`timescale 1ns/1ps

// 512-byte dual-clock ready/valid FIFO.  Reset-busy is exposed so callers can
// gate arm and transfer state until both XPM domains have completed reset.
module link_async_fifo (
  input  logic       wr_clk_i,
  input  logic       wr_resetn_i,
  input  logic [7:0] wr_data_i,
  input  logic       wr_valid_i,
  output logic       wr_ready_o,
  output logic       wr_reset_busy_o,
  output logic [9:0] wr_free_bytes_o,

  input  logic       rd_clk_i,
  input  logic       rd_resetn_i,
  output logic [7:0] rd_data_o,
  output logic       rd_valid_o,
  input  logic       rd_ready_i,
  output logic       rd_reset_busy_o
);
  logic fifo_full;
  logic fifo_empty;
  logic fifo_reset;
  logic wr_enable;
  logic rd_enable;
  logic [9:0] wr_data_count;
  (* ASYNC_REG = "TRUE" *) logic [3:0] rd_resetn_sync_wr = 4'b0000;
  logic [4:0] fifo_reset_hold_wr = 5'b11111;

  // XPM requires rst to be synchronous to wr_clk and asserted for at least
  // five writer-clock edges.  The opposite-domain reset is first synchronized
  // into the writer domain; link safety gates traffic independently while a
  // stopped writer clock waits to observe reset.
  always_ff @(posedge wr_clk_i) begin
    rd_resetn_sync_wr <= {rd_resetn_sync_wr[2:0], rd_resetn_i};
    if (!wr_resetn_i || !rd_resetn_sync_wr[3])
      fifo_reset_hold_wr <= 5'b11111;
    else
      fifo_reset_hold_wr <= {fifo_reset_hold_wr[3:0], 1'b0};
  end

  assign fifo_reset = fifo_reset_hold_wr[4];
  assign wr_ready_o = !fifo_full && !wr_reset_busy_o;
  // wr_data_count uses the write-domain view of the synchronized read pointer,
  // so it may overestimate occupancy during active reads but never grants
  // unsafe frame space.
  assign wr_free_bytes_o = 10'd512 - wr_data_count;
  assign wr_enable = wr_valid_i && wr_ready_o;
  assign rd_valid_o = !fifo_empty && !rd_reset_busy_o;
  assign rd_enable = rd_valid_o && rd_ready_i;

  xpm_fifo_async #(
    .CDC_SYNC_STAGES       (4),
    .DOUT_RESET_VALUE      ("0"),
    .ECC_MODE              ("no_ecc"),
    .FIFO_MEMORY_TYPE      ("block"),
    .FIFO_READ_LATENCY     (0),
    .FIFO_WRITE_DEPTH      (512),
    .FULL_RESET_VALUE      (0),
    .PROG_EMPTY_THRESH     (10),
    .PROG_FULL_THRESH      (502),
    .RD_DATA_COUNT_WIDTH   (10),
    .READ_DATA_WIDTH       (8),
    .READ_MODE             ("fwft"),
    .RELATED_CLOCKS        (0),
    .SIM_ASSERT_CHK        (1),
    .USE_ADV_FEATURES      ("0000"),
    .WAKEUP_TIME           (0),
    .WRITE_DATA_WIDTH      (8),
    .WR_DATA_COUNT_WIDTH   (10)
  ) fifo_i (
    .almost_empty          (),
    .almost_full           (),
    .data_valid            (),
    .dbiterr               (),
    .dout                  (rd_data_o),
    .empty                 (fifo_empty),
    .full                  (fifo_full),
    .overflow              (),
    .prog_empty            (),
    .prog_full             (),
    .rd_data_count         (),
    .rd_rst_busy           (rd_reset_busy_o),
    .sbiterr               (),
    .underflow             (),
    .wr_ack                (),
    .wr_data_count         (wr_data_count),
    .wr_rst_busy           (wr_reset_busy_o),
    .din                   (wr_data_i),
    .injectdbiterr         (1'b0),
    .injectsbiterr         (1'b0),
    .rd_clk                (rd_clk_i),
    .rd_en                 (rd_enable),
    .rst                   (fifo_reset),
    .sleep                 (1'b0),
    .wr_clk                (wr_clk_i),
    .wr_en                 (wr_enable)
  );
endmodule
