`timescale 1ns/1ps

module tb_link_endpoint;
  logic local_clk = 1'b0;
  logic link_clk = 1'b0;
  logic resetn = 1'b0;
  always #8.5 local_clk = ~local_clk;
  always #10 link_clk = ~link_clk;

  logic [7:0] tx_data = 8'd0;
  logic tx_valid = 1'b0;
  wire tx_ready;
  wire [7:0] rx_data;
  wire rx_valid;
  logic rx_ready = 1'b1;
  logic arm = 1'b0;
  wire [1:0] lanes;
  logic [15:0] tx_first_sequence = 16'd0;
  logic [15:0] rx_first_sequence = 16'd0;
  logic [15:0] tx_frame_limit = 16'd16;
  logic corrupt_enable = 1'b0;
  wire corrupt_now = corrupt_enable && (dut.tx_framer.state == 4'd7) &&
                     (dut.tx_framer.payload_index == 9'd10) &&
                     (dut.tx_framer.pair_index == 2'd0);
  wire [1:0] rx_lanes = lanes ^ (corrupt_now ? 2'b01 : 2'b00);
  wire tx_active;
  wire tx_done;
  wire tx_underflow;
  wire [15:0] last_sequence;
  wire [31:0] tx_frames;
  wire [31:0] rx_frames;
  wire [31:0] crc_errors;
  wire [31:0] sequence_errors;
  wire [31:0] overflow_errors;
  wire [31:0] safety_disarms;
  int rx_index = 0;
  int loaded_count = 0;
  logic [7:0] wire_byte = 8'd0;
  logic [1:0] wire_pair = 2'd0;
  int wire_byte_index = 0;

  function automatic [7:0] vector_byte(input int index);
    vector_byte = ((index * 73) ^ (index >> 3) ^ (index >> 8) ^ 8'hA5) & 8'hFF;
  endfunction

  minimal_link_core dut (
    .local_clk_i(local_clk), .local_resetn_i(resetn),
    .tx_data_i(tx_data), .tx_valid_i(tx_valid), .tx_ready_o(tx_ready),
    .rx_data_o(rx_data), .rx_valid_o(rx_valid), .rx_ready_i(rx_ready),
    .tx_link_clk_i(link_clk), .rx_link_clk_i(link_clk),
    .tx_arm_i(arm), .tx_direction_i(2'd1), .tx_first_sequence_i(tx_first_sequence),
    .tx_payload_length_i(9'd256), .tx_frame_limit_i(tx_frame_limit),
    .rx_arm_i(arm), .rx_expected_direction_i(2'd1), .rx_first_sequence_i(rx_first_sequence),
    .tx_lane_o(lanes), .rx_lane_i(rx_lanes),
    .tx_active_o(tx_active), .tx_transaction_done_o(tx_done),
    .tx_underflow_o(tx_underflow), .rx_last_sequence_o(last_sequence),
    .tx_frame_count_o(tx_frames), .rx_frame_count_o(rx_frames),
    .crc_error_count_o(crc_errors), .sequence_error_count_o(sequence_errors),
    .overflow_count_o(overflow_errors), .safety_disarm_count_o(safety_disarms)
  );

  always @(posedge local_clk) begin
    if (rx_valid && rx_ready) begin
      if (rx_data !== vector_byte(rx_index))
        $fatal(1, "payload mismatch index=%0d got=%02x expected=%02x", rx_index, rx_data, vector_byte(rx_index));
      rx_index++;
    end
  end

  always @(posedge link_clk) begin
    if (tx_active && (wire_byte_index < 10)) begin
      wire_byte[wire_pair*2 +: 2] = lanes;
      if (wire_pair == 2'd3) begin
        case (wire_byte_index)
          0: if (wire_byte !== 8'hA5) $fatal(1, "wire sync0 mismatch");
          1: if (wire_byte !== 8'h5A) $fatal(1, "wire sync1 mismatch");
          2: if (wire_byte !== 8'hC3) $fatal(1, "wire sync2 mismatch");
          3: if (wire_byte !== 8'h3C) $fatal(1, "wire sync3 mismatch");
          4: if (wire_byte !== 8'h14) $fatal(1, "wire control mismatch %02x", wire_byte);
          5,6: if (wire_byte !== 8'h00) $fatal(1, "wire sequence mismatch");
          7: if (wire_byte !== 8'h00) $fatal(1, "wire length low mismatch");
          8: if (wire_byte !== 8'h01) $fatal(1, "wire length high mismatch");
          9: if (wire_byte !== vector_byte(0)) $fatal(1, "wire first payload mismatch");
        endcase
        wire_byte_index++;
        wire_pair = 2'd0;
        wire_byte = 8'd0;
      end else begin
        wire_pair++;
      end
    end
    if (dut.rx_crc_error)
      $display("CRC_DIAG received=%08x expected=%08x state=%08x payload_len=%0d seq=%0d",
        dut.rx_parser.received_crc, ~dut.rx_parser.crc_state,
        dut.rx_parser.crc_state, dut.rx_parser.payload_length,
        dut.rx_parser.received_sequence);
  end

  task automatic load_bytes(input int base_index, input int byte_count);
    begin
      for (int index = 0; index < byte_count; index++) begin
        @(negedge local_clk);
        tx_data = vector_byte(base_index + index);
        tx_valid = 1'b1;
        do @(posedge local_clk); while (!tx_ready);
        loaded_count++;
      end
      @(negedge local_clk);
      tx_valid = 1'b0;
      tx_data = 8'd0;
    end
  endtask

  initial begin
    repeat (5) @(posedge local_clk);
    resetn = 1'b1;
    repeat (20) @(posedge local_clk);

    // Exercise the exact finite payload: the writer and 50 MHz reader run
    // concurrently across the async FIFO for sixteen zero-gap frames.
    fork
      load_bytes(0, 4096);
    join_none
    wait (loaded_count >= 256);
    repeat (8) @(posedge link_clk);
    arm = 1'b1;
    fork
      begin
        repeat (200000) @(posedge link_clk);
        $fatal(1, "endpoint timeout rx_index=%0d tx_frames=%0d rx_frames=%0d crc=%0d seq=%0d overflow=%0d underflow=%0b active=%0b done=%0b lanes=%b parser_state=%0d pair=%0d sync=%0d header=%0b drain=%0b",
          rx_index, tx_frames, rx_frames, crc_errors, sequence_errors,
          overflow_errors, tx_underflow, tx_active, tx_done, lanes,
          dut.rx_parser.state, dut.rx_parser.pair_index,
          dut.rx_parser.sync_index, dut.rx_parser.header_valid,
          dut.rx_parser.drain_active);
      end
      begin
        wait (rx_index == 4096);
        wait (loaded_count == 4096);
        repeat (8) @(posedge local_clk);
        if (tx_frames != 16 || rx_frames != 16 || last_sequence != 15)
          $fatal(1, "frame status mismatch tx=%0d rx=%0d seq=%0d", tx_frames, rx_frames, last_sequence);
        if (crc_errors || sequence_errors || overflow_errors || tx_underflow)
          $fatal(1, "unexpected error crc=%0d seq=%0d overflow=%0d underflow=%0b", crc_errors, sequence_errors, overflow_errors, tx_underflow);
        arm = 1'b0;
        repeat (8) @(posedge link_clk);

        // A CRC-clean frame with the wrong expected sequence must not commit.
        tx_frame_limit = 16'd1;
        tx_first_sequence = 16'd0;
        rx_first_sequence = 16'd1;
        repeat (4) @(posedge link_clk);
        load_bytes(4096, 256);
        repeat (4) @(posedge link_clk);
        arm = 1'b1;
        wait (sequence_errors == 1 && tx_frames == 1);
        repeat (8) @(posedge link_clk);
        if (rx_frames != 0 || rx_index != 4096)
          $fatal(1, "sequence-error frame committed payload");
        arm = 1'b0;
        repeat (8) @(posedge link_clk);

        // One payload-bit corruption must fail CRC and never commit.
        tx_first_sequence = 16'd0;
        rx_first_sequence = 16'd0;
        corrupt_enable = 1'b1;
        repeat (4) @(posedge link_clk);
        load_bytes(4352, 256);
        repeat (4) @(posedge link_clk);
        arm = 1'b1;
        wait (crc_errors == 1 && tx_frames == 1);
        repeat (8) @(posedge link_clk);
        if (rx_frames != 0 || rx_index != 4096)
          $fatal(1, "corrupt frame committed payload");
        corrupt_enable = 1'b0;
        arm = 1'b0;
        repeat (8) @(posedge link_clk);

        // An asynchronous mid-transaction reset must abort without leaving
        // the link active; release is intentionally off phase to both clocks.
        tx_first_sequence = 16'd0;
        rx_first_sequence = 16'd0;
        load_bytes(4608, 256);
        repeat (4) @(posedge link_clk);
        arm = 1'b1;
        wait (tx_active);
        repeat (10) @(posedge link_clk);
        #3 resetn = 1'b0;
        #7;
        if (tx_active) $fatal(1, "mid-transaction reset failed to abort TX");
        arm = 1'b0;
        #11 resetn = 1'b1;
        repeat (20) @(posedge local_clk);
        if (tx_active) $fatal(1, "TX re-enabled after reset without fresh arm");
        $display("TB_LINK_ENDPOINT=PASS");
        $finish;
      end
    join
  end
endmodule
