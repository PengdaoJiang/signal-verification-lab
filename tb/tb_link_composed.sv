`timescale 1ns/1ps

module tb_link_composed;
  logic local_a = 1'b0;
  logic local_b = 1'b0;
  logic link_a = 1'b0;
  logic link_b = 1'b0;
  logic resetn = 1'b0;
  always #8.0 local_a = ~local_a;
  always #9.0 local_b = ~local_b;
  always #10.0 link_a = ~link_a;
  initial begin #3.0; forever #10.0 link_b = ~link_b; end

  logic [7:0] tx_a_data = 0;
  logic tx_a_valid = 0;
  wire tx_a_ready;
  logic [7:0] tx_b_data = 0;
  logic tx_b_valid = 0;
  wire tx_b_ready;
  wire [7:0] rx_a_data;
  wire rx_a_valid;
  wire [7:0] rx_b_data;
  wire rx_b_valid;
  logic arm = 0;
  wire [1:0] lanes_a_to_b;
  wire [1:0] lanes_b_to_a;
  wire [31:0] tx_a_frames, rx_a_frames, tx_b_frames, rx_b_frames;
  wire [31:0] a_crc, a_seq, a_overflow, a_safety;
  wire [31:0] b_crc, b_seq, b_overflow, b_safety;
  wire a_underflow, b_underflow;
  int rx_a_index = 0;
  int rx_b_index = 0;
  int a_link_cycles = 0;
  int b_link_cycles = 0;
  int a_last_done = -1;
  int b_last_done = -1;
  int loaded_a = 0;
  int loaded_b = 0;
  localparam int TOTAL_BYTES = 4096;

  function automatic [7:0] byte_a(input int index);
    byte_a = ((index * 73) ^ (index >> 3) ^ 8'hA5) & 8'hFF;
  endfunction
  function automatic [7:0] byte_b(input int index);
    byte_b = ((index * 29) ^ (index >> 2) ^ 8'h3C) & 8'hFF;
  endfunction

  minimal_link_core endpoint_a (
    .local_clk_i(local_a), .local_resetn_i(resetn),
    .tx_data_i(tx_a_data), .tx_valid_i(tx_a_valid), .tx_ready_o(tx_a_ready),
    .rx_data_o(rx_a_data), .rx_valid_o(rx_a_valid), .rx_ready_i(1'b1),
    .tx_link_clk_i(link_a), .rx_link_clk_i(link_b),
    .tx_arm_i(arm), .tx_direction_i(2'd1), .tx_first_sequence_i(16'd0),
    .tx_payload_length_i(9'd256), .tx_frame_limit_i(16'd16),
    .rx_arm_i(arm), .rx_expected_direction_i(2'd2), .rx_first_sequence_i(16'd0),
    .tx_lane_o(lanes_a_to_b), .rx_lane_i(lanes_b_to_a),
    .tx_active_o(), .tx_transaction_done_o(), .tx_underflow_o(a_underflow),
    .rx_last_sequence_o(), .tx_frame_count_o(tx_a_frames), .rx_frame_count_o(rx_a_frames),
    .crc_error_count_o(a_crc), .sequence_error_count_o(a_seq),
    .overflow_count_o(a_overflow), .safety_disarm_count_o(a_safety)
  );

  minimal_link_core endpoint_b (
    .local_clk_i(local_b), .local_resetn_i(resetn),
    .tx_data_i(tx_b_data), .tx_valid_i(tx_b_valid), .tx_ready_o(tx_b_ready),
    .rx_data_o(rx_b_data), .rx_valid_o(rx_b_valid), .rx_ready_i(1'b1),
    .tx_link_clk_i(link_b), .rx_link_clk_i(link_a),
    .tx_arm_i(arm), .tx_direction_i(2'd2), .tx_first_sequence_i(16'd0),
    .tx_payload_length_i(9'd256), .tx_frame_limit_i(16'd16),
    .rx_arm_i(arm), .rx_expected_direction_i(2'd1), .rx_first_sequence_i(16'd0),
    .tx_lane_o(lanes_b_to_a), .rx_lane_i(lanes_a_to_b),
    .tx_active_o(), .tx_transaction_done_o(), .tx_underflow_o(b_underflow),
    .rx_last_sequence_o(), .tx_frame_count_o(tx_b_frames), .rx_frame_count_o(rx_b_frames),
    .crc_error_count_o(b_crc), .sequence_error_count_o(b_seq),
    .overflow_count_o(b_overflow), .safety_disarm_count_o(b_safety)
  );

  always @(posedge local_a) if (rx_a_valid) begin
    if (rx_a_data !== byte_b(rx_a_index))
      $fatal(1, "A receive mismatch index=%0d", rx_a_index);
    rx_a_index++;
  end
  always @(posedge local_b) if (rx_b_valid) begin
    if (rx_b_data !== byte_a(rx_b_index))
      $fatal(1, "B receive mismatch index=%0d", rx_b_index);
    rx_b_index++;
  end

  always @(posedge link_a) begin
    a_link_cycles++;
    if (endpoint_a.tx_frame_done) begin
      if (a_last_done >= 0 && (a_link_cycles - a_last_done) != 1076)
        $fatal(1, "A inter-frame bubble delta=%0d", a_link_cycles-a_last_done);
      a_last_done = a_link_cycles;
    end
  end
  always @(posedge link_b) begin
    b_link_cycles++;
    if (endpoint_b.tx_frame_done) begin
      if (b_last_done >= 0 && (b_link_cycles - b_last_done) != 1076)
        $fatal(1, "B inter-frame bubble delta=%0d", b_link_cycles-b_last_done);
      b_last_done = b_link_cycles;
    end
  end

  task automatic load_a;
    for (int index=0; index<TOTAL_BYTES; index++) begin
      @(negedge local_a); tx_a_data=byte_a(index); tx_a_valid=1;
      do @(posedge local_a); while(!tx_a_ready);
      loaded_a++;
    end
    @(negedge local_a); tx_a_valid=0;
  endtask
  task automatic load_b;
    for (int index=0; index<TOTAL_BYTES; index++) begin
      @(negedge local_b); tx_b_data=byte_b(index); tx_b_valid=1;
      do @(posedge local_b); while(!tx_b_ready);
      loaded_b++;
    end
    @(negedge local_b); tx_b_valid=0;
  endtask

  initial begin
    repeat(5) @(posedge local_a); resetn=1;
    repeat(20) @(posedge local_a);
    fork load_a(); load_b(); join_none
    wait(loaded_a >= 256 && loaded_b >= 256);
    repeat(8) @(posedge link_a); arm=1;
    fork
      begin repeat(200000) @(posedge link_a); $fatal(1,"composed timeout"); end
      begin
        wait(rx_a_index==TOTAL_BYTES && rx_b_index==TOTAL_BYTES);
        repeat(8) @(posedge local_a);
        if(tx_a_frames!=16 || tx_b_frames!=16 || rx_a_frames!=16 || rx_b_frames!=16)
          $fatal(1,"frame count mismatch");
        if(a_crc||a_seq||a_overflow||a_underflow||b_crc||b_seq||b_overflow||b_underflow)
          $fatal(1,"unexpected full-duplex error");
        arm=0;
        repeat(8) @(posedge link_a);
        $display("TB_LINK_COMPOSED=PASS");
        $finish;
      end
    join
  end
endmodule
