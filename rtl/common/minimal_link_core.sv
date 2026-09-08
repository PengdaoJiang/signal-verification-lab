`timescale 1ns/1ps

module minimal_link_core (
  input  wire        local_clk_i,
  input  wire        local_resetn_i,
  input  wire [7:0]  tx_data_i,
  input  wire        tx_valid_i,
  output wire        tx_ready_o,
  output wire [7:0]  rx_data_o,
  output wire        rx_valid_o,
  input  wire        rx_ready_i,

  input  wire        tx_link_clk_i,
  input  wire        rx_link_clk_i,
  input  wire        tx_arm_i,
  input  wire [1:0]  tx_direction_i,
  input  wire [15:0] tx_first_sequence_i,
  input  wire [8:0]  tx_payload_length_i,
  input  wire [15:0] tx_frame_limit_i,
  input  wire        rx_arm_i,
  input  wire [1:0]  rx_expected_direction_i,
  input  wire [15:0] rx_first_sequence_i,
  output wire [1:0]  tx_lane_o,
  input  wire [1:0]  rx_lane_i,

  output wire        tx_active_o,
  output wire        tx_transaction_done_o,
  output wire        tx_underflow_o,
  output wire [15:0] rx_last_sequence_o,
  output wire [31:0] tx_frame_count_o,
  output wire [31:0] rx_frame_count_o,
  output wire [31:0] crc_error_count_o,
  output wire [31:0] sequence_error_count_o,
  output wire [31:0] overflow_count_o,
  output wire [31:0] safety_disarm_count_o
);
  wire local_resetn;
  wire tx_resetn;
  wire rx_resetn;
  (* ASYNC_REG = "TRUE" *) logic [1:0] tx_arm_sync;
  (* ASYNC_REG = "TRUE" *) logic [1:0] rx_arm_sync;

  link_reset_sync local_reset_sync (
    .clk_i(local_clk_i), .async_resetn_i(local_resetn_i), .resetn_o(local_resetn)
  );
  link_reset_sync tx_reset_sync (
    .clk_i(tx_link_clk_i), .async_resetn_i(local_resetn_i), .resetn_o(tx_resetn)
  );
  link_reset_sync rx_reset_sync (
    .clk_i(rx_link_clk_i), .async_resetn_i(local_resetn_i), .resetn_o(rx_resetn)
  );

  // PREPARE holds each associated context bundle stable before the level is
  // raised and throughout the transaction.  Only the one-bit arm event is
  // synchronized; the destination captures the held context when it observes
  // that synchronized level.
  always_ff @(posedge tx_link_clk_i or negedge tx_resetn) begin
    if (!tx_resetn) tx_arm_sync <= 2'b00;
    else tx_arm_sync <= {tx_arm_sync[0], tx_arm_i};
  end
  always_ff @(posedge rx_link_clk_i or negedge rx_resetn) begin
    if (!rx_resetn) rx_arm_sync <= 2'b00;
    else rx_arm_sync <= {rx_arm_sync[0], rx_arm_i};
  end

  wire [7:0] tx_fifo_data;
  wire tx_fifo_valid;
  wire tx_fifo_ready;
  wire tx_fifo_wr_busy;
  wire tx_fifo_rd_busy;
  wire [9:0] tx_fifo_free_unused;
  link_async_fifo tx_fifo (
    .wr_clk_i(local_clk_i), .wr_resetn_i(local_resetn),
    .wr_data_i(tx_data_i), .wr_valid_i(tx_valid_i), .wr_ready_o(tx_ready_o),
    .wr_reset_busy_o(tx_fifo_wr_busy),
    .wr_free_bytes_o(tx_fifo_free_unused),
    .rd_clk_i(tx_link_clk_i), .rd_resetn_i(tx_resetn),
    .rd_data_o(tx_fifo_data), .rd_valid_o(tx_fifo_valid), .rd_ready_i(tx_fifo_ready),
    .rd_reset_busy_o(tx_fifo_rd_busy)
  );

  wire tx_frame_done;
  wire tx_underflow;
  link_tx_framer tx_framer (
    .clk_i(tx_link_clk_i), .resetn_i(tx_resetn),
    .arm_i(tx_arm_sync[1] && !tx_fifo_rd_busy),
    .direction_i(tx_direction_i), .first_sequence_i(tx_first_sequence_i),
    .payload_length_i(tx_payload_length_i), .frame_limit_i(tx_frame_limit_i),
    .data_i(tx_fifo_data), .data_valid_i(tx_fifo_valid), .data_ready_o(tx_fifo_ready),
    .lane_o(tx_lane_o), .active_o(tx_active_o), .frame_done_o(tx_frame_done),
    .transaction_done_o(tx_transaction_done_o), .underflow_o(tx_underflow)
  );

  wire [7:0] parsed_data;
  wire parsed_valid;
  wire parsed_ready;
  wire rx_frame_done;
  wire rx_crc_error;
  wire rx_sequence_error;
  wire rx_parser_overflow;
  wire [9:0] rx_fifo_free;
  link_rx_parser rx_parser (
    .clk_i(rx_link_clk_i), .resetn_i(rx_resetn),
    .arm_i(rx_arm_sync[1]), .expected_direction_i(rx_expected_direction_i),
    .first_sequence_i(rx_first_sequence_i), .lane_i(rx_lane_i),
    .data_o(parsed_data), .data_valid_o(parsed_valid), .data_ready_i(parsed_ready),
    .commit_space_i(rx_fifo_free),
    .frame_done_o(rx_frame_done), .crc_error_o(rx_crc_error),
    .sequence_error_o(rx_sequence_error), .overflow_o(rx_parser_overflow),
    .last_sequence_o(rx_last_sequence_o)
  );

  wire rx_fifo_wr_busy;
  wire rx_fifo_rd_busy;
  link_async_fifo rx_fifo (
    .wr_clk_i(rx_link_clk_i), .wr_resetn_i(rx_resetn),
    .wr_data_i(parsed_data), .wr_valid_i(parsed_valid), .wr_ready_o(parsed_ready),
    .wr_reset_busy_o(rx_fifo_wr_busy),
    .wr_free_bytes_o(rx_fifo_free),
    .rd_clk_i(local_clk_i), .rd_resetn_i(local_resetn),
    .rd_data_o(rx_data_o), .rd_valid_o(rx_valid_o), .rd_ready_i(rx_ready_i),
    .rd_reset_busy_o(rx_fifo_rd_busy)
  );

  function automatic [31:0] sat_inc(input [31:0] value);
    sat_inc = (&value) ? value : value + 1'b1;
  endfunction

  logic [31:0] tx_frame_count;
  logic [31:0] rx_frame_count;
  logic [31:0] crc_error_count;
  logic [31:0] sequence_error_count;
  logic [31:0] overflow_count;
  logic [31:0] safety_disarm_count;
  logic tx_arm_seen;
  logic rx_arm_seen;

  always_ff @(posedge tx_link_clk_i or negedge tx_resetn) begin
    if (!tx_resetn) begin
      tx_frame_count <= 32'd0;
      safety_disarm_count <= 32'd0;
      tx_arm_seen <= 1'b0;
    end else begin
      if (tx_arm_sync[1] && !tx_arm_seen) begin
        // All observable counters are transaction-local in the compact ABI.
        tx_frame_count <= 32'd0;
        safety_disarm_count <= 32'd0;
        tx_arm_seen <= 1'b1;
      end else if (tx_frame_done) begin
        tx_frame_count <= sat_inc(tx_frame_count);
      end
      if (tx_arm_seen && !tx_arm_sync[1]) begin
        safety_disarm_count <= sat_inc(safety_disarm_count);
        tx_arm_seen <= 1'b0;
      end
    end
  end

  always_ff @(posedge rx_link_clk_i or negedge rx_resetn) begin
    if (!rx_resetn) begin
      rx_frame_count <= 32'd0;
      crc_error_count <= 32'd0;
      sequence_error_count <= 32'd0;
      overflow_count <= 32'd0;
      rx_arm_seen <= 1'b0;
    end else begin
      if (rx_arm_sync[1] && !rx_arm_seen) begin
        rx_frame_count <= 32'd0;
        crc_error_count <= 32'd0;
        sequence_error_count <= 32'd0;
        overflow_count <= 32'd0;
        rx_arm_seen <= 1'b1;
      end else begin
        if (rx_frame_done) rx_frame_count <= sat_inc(rx_frame_count);
        if (rx_crc_error) crc_error_count <= sat_inc(crc_error_count);
        if (rx_sequence_error) sequence_error_count <= sat_inc(sequence_error_count);
        if (rx_parser_overflow) overflow_count <= sat_inc(overflow_count);
      end
      if (!rx_arm_sync[1])
        rx_arm_seen <= 1'b0;
    end
  end

  assign tx_frame_count_o = tx_frame_count;
  assign tx_underflow_o = tx_underflow;
  assign rx_frame_count_o = rx_frame_count;
  assign crc_error_count_o = crc_error_count;
  assign sequence_error_count_o = sequence_error_count;
  assign overflow_count_o = overflow_count;
  assign safety_disarm_count_o = safety_disarm_count;
endmodule
