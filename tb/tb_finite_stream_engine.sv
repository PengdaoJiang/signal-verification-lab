`timescale 1ns/1ps
`default_nettype none

module tb_finite_stream_engine;
  localparam logic [3:0] OP_CLEAR      = 4'd1;
  localparam logic [3:0] OP_LOAD       = 4'd2;
  localparam logic [3:0] OP_QUIESCE    = 4'd3;
  localparam logic [3:0] OP_ARM_FOLLOW = 4'd4;
  localparam logic [3:0] OP_ARM_INIT   = 4'd5;
  localparam logic [3:0] OP_START      = 4'd6;
  localparam logic [3:0] OP_READ       = 4'd7;
  localparam logic [3:0] OP_STATUS     = 4'd8;

  logic txclk = 1'b0;
  wire rxclk = txclk;
  logic mgmt_clk = 1'b0;
  always #1.5515 txclk = ~txclk;
  always #5.0 mgmt_clk = ~mgmt_clk;

  logic reset = 1'b1;
  logic req_valid_a, req_valid_b;
  wire req_ready_a, req_ready_b;
  logic req_toggle_a, req_toggle_b;
  logic [3:0] req_opcode_a, req_opcode_b;
  logic [5:0] req_index_a, req_index_b;
  logic [15:0] req_tag_a, req_tag_b;
  logic [511:0] req_data_a, req_data_b;
  wire rsp_valid_a, rsp_valid_b;
  logic rsp_ready_a = 1'b0;
  logic rsp_ready_b = 1'b0;
  wire rsp_toggle_a, rsp_toggle_b;
  wire [3:0] rsp_code_a, rsp_code_b;
  wire [5:0] rsp_index_a, rsp_index_b;
  wire [511:0] rsp_data_a, rsp_data_b;
  wire [127:0] rsp_status_a, rsp_status_b;
  logic [3:0] vendor_ena_a, vendor_ena_b;
  logic [3:0] vendor_eop_a, vendor_eop_b;
  logic tx_rdy_a = 1'b1;
  logic tx_rdy_b = 1'b1;
  wire select_a, select_b;
  wire [511:0] tx_data_a, tx_data_b;
  wire [3:0] tx_ena_a, tx_ena_b;
  wire [3:0] tx_sop_a, tx_sop_b;
  wire [3:0] tx_eop_a, tx_eop_b;
  wire [15:0] tx_mty_a, tx_mty_b;
  wire [3:0] tx_err_a, tx_err_b;
  // CMAC LBUS tx_rdyout is not a same-cycle qualifier.  Every ENA cycle is
  // transferred, including the cycle in which ready falls; ready only asks
  // the source to halt within four cycles.
  wire [3:0] link_ena_a = tx_ena_a;
  wire [3:0] link_ena_b = tx_ena_b;
  wire [3:0] link_sop_a = tx_sop_a;
  wire [3:0] link_sop_b = tx_sop_b;
  wire [3:0] link_eop_a = tx_eop_a;
  wire [3:0] link_eop_b = tx_eop_b;
  logic rx_override_b = 1'b0;
  logic [511:0] rx_override_data_b = 512'b0;
  logic [3:0] rx_override_ena_b = 4'b0;
  logic [3:0] rx_override_sop_b = 4'b0;
  logic [3:0] rx_override_eop_b = 4'b0;
  logic [15:0] rx_override_mty_b = 16'b0;
  logic [3:0] rx_override_err_b = 4'b0;
  logic rx_fcs_error_b = 1'b0;
  logic rx_fec_corrected_b = 1'b0;
  logic rx_fec_uncorrectable_b = 1'b0;
  logic inject_terminal_rx_err_b = 1'b0;
  wire [511:0] rx_data_b = rx_override_b ? rx_override_data_b : tx_data_a;
  wire [3:0] rx_ena_b = rx_override_b ? rx_override_ena_b : link_ena_a;
  wire [3:0] rx_sop_b = rx_override_b ? rx_override_sop_b : link_sop_a;
  wire [3:0] rx_eop_b = rx_override_b ? rx_override_eop_b : link_eop_a;
  wire [15:0] rx_mty_b = rx_override_b ? rx_override_mty_b : tx_mty_a;
  wire [3:0] rx_err_b = rx_override_b ? rx_override_err_b :
    ((inject_terminal_rx_err_b && |link_eop_a) ? 4'h8 : tx_err_a);
  wire [127:0] live_status_a, live_status_b;
  integer overlap_cycles = 0;
  logic backpressure_exercised = 1'b0;

  finite_stream_engine dut_a (
    .txusrclk2_i(txclk), .tx_reset_i(reset),
    .rxusrclk2_i(rxclk), .rx_reset_i(reset),
    .request_valid_i(req_valid_a), .request_ready_o(req_ready_a),
    .request_toggle_i(req_toggle_a), .request_opcode_i(req_opcode_a),
    .request_word_index_i(req_index_a), .request_tag_i(req_tag_a),
    .request_data_i(req_data_a), .response_valid_o(rsp_valid_a),
    .response_ready_i(rsp_ready_a), .response_toggle_o(rsp_toggle_a),
    .response_code_o(rsp_code_a), .response_word_index_o(rsp_index_a),
    .response_data_o(rsp_data_a), .response_status_o(rsp_status_a),
    .vendor_tx_ena_i(vendor_ena_a), .vendor_tx_eop_i(vendor_eop_a),
    .cmac_tx_rdy_i(tx_rdy_a), .finite_select_o(select_a),
    .finite_tx_data_o(tx_data_a), .finite_tx_ena_o(tx_ena_a),
    .finite_tx_sop_o(tx_sop_a), .finite_tx_eop_o(tx_eop_a),
    .finite_tx_mty_o(tx_mty_a), .finite_tx_err_o(tx_err_a),
    .rx_data_i(tx_data_b), .rx_ena_i(link_ena_b), .rx_sop_i(link_sop_b),
    .rx_eop_i(link_eop_b), .rx_mty_i(tx_mty_b), .rx_err_i(tx_err_b),
    .rx_fcs_error_i(1'b0), .rx_fec_corrected_i(1'b0),
    .rx_fec_uncorrectable_i(1'b0), .live_status_o(live_status_a)
  );

  finite_stream_engine dut_b (
    .txusrclk2_i(txclk), .tx_reset_i(reset),
    .rxusrclk2_i(rxclk), .rx_reset_i(reset),
    .request_valid_i(req_valid_b), .request_ready_o(req_ready_b),
    .request_toggle_i(req_toggle_b), .request_opcode_i(req_opcode_b),
    .request_word_index_i(req_index_b), .request_tag_i(req_tag_b),
    .request_data_i(req_data_b), .response_valid_o(rsp_valid_b),
    .response_ready_i(rsp_ready_b), .response_toggle_o(rsp_toggle_b),
    .response_code_o(rsp_code_b), .response_word_index_o(rsp_index_b),
    .response_data_o(rsp_data_b), .response_status_o(rsp_status_b),
    .vendor_tx_ena_i(vendor_ena_b), .vendor_tx_eop_i(vendor_eop_b),
    .cmac_tx_rdy_i(tx_rdy_b), .finite_select_o(select_b),
    .finite_tx_data_o(tx_data_b), .finite_tx_ena_o(tx_ena_b),
    .finite_tx_sop_o(tx_sop_b), .finite_tx_eop_o(tx_eop_b),
    .finite_tx_mty_o(tx_mty_b), .finite_tx_err_o(tx_err_b),
    .rx_data_i(rx_data_b), .rx_ena_i(rx_ena_b), .rx_sop_i(rx_sop_b),
    .rx_eop_i(rx_eop_b), .rx_mty_i(rx_mty_b), .rx_err_i(rx_err_b),
    .rx_fcs_error_i(rx_fcs_error_b),
    .rx_fec_corrected_i(rx_fec_corrected_b),
    .rx_fec_uncorrectable_i(rx_fec_uncorrectable_b),
    .live_status_o(live_status_b)
  );

  // One bridge-only instance proves the 539/651-bit XPM handshake ABI with
  // asynchronous 100 MHz management and 322.265625 MHz source clocks.
  logic bridge_mgmt_reset = 1'b1;
  logic bridge_tx_reset = 1'b1;
  logic [31:0] bridge_request = 32'b0;
  logic [511:0] bridge_source = 512'b0;
  wire [127:0] bridge_status;
  wire [511:0] bridge_capture;
  wire bridge_select;
  wire [511:0] bridge_tx_data;
  wire [3:0] bridge_tx_ena, bridge_tx_sop, bridge_tx_eop, bridge_tx_err;
  wire [15:0] bridge_tx_mty;

  finite_stream_bridge bridge_dut (
    .mgmt_clk_i(mgmt_clk), .mgmt_reset_i(bridge_mgmt_reset),
    .vio_request_i(bridge_request), .vio_source_data_i(bridge_source),
    .vio_status_o(bridge_status), .vio_capture_data_o(bridge_capture),
    .txusrclk2_i(txclk), .tx_reset_i(bridge_tx_reset),
    .rxusrclk2_i(rxclk), .rx_reset_i(bridge_tx_reset),
    .vendor_tx_ena_i(4'b0), .vendor_tx_eop_i(4'b0),
    .cmac_tx_rdy_i(1'b1), .finite_select_o(bridge_select),
    .finite_tx_data_o(bridge_tx_data), .finite_tx_ena_o(bridge_tx_ena),
    .finite_tx_sop_o(bridge_tx_sop), .finite_tx_eop_o(bridge_tx_eop),
    .finite_tx_mty_o(bridge_tx_mty), .finite_tx_err_o(bridge_tx_err),
    .rx_data_i(512'b0), .rx_ena_i(4'b0), .rx_sop_i(4'b0),
    .rx_eop_i(4'b0), .rx_mty_i(16'b0), .rx_err_i(4'b0),
    .rx_fcs_error_i(1'b0), .rx_fec_corrected_i(1'b0),
    .rx_fec_uncorrectable_i(1'b0)
  );

  function automatic logic [7:0] vector_a_byte(input integer index);
    vector_a_byte = ((index * 73) ^ (index >> 3) ^
                     (index >> 8) ^ 8'hA5) & 8'hFF;
  endfunction

  function automatic logic [7:0] vector_b_byte(input integer index);
    vector_b_byte = ((index * 151) ^ (index >> 2) ^
                     (index >> 7) ^ 8'h3C) & 8'hFF;
  endfunction

  function automatic logic [511:0] vector_word(
    input bit vector_b,
    input integer word_index
  );
    logic [511:0] value;
    integer byte_index;
    begin
      value = 512'b0;
      for (byte_index = 0; byte_index < 64; byte_index = byte_index + 1)
        value[byte_index*8 +: 8] = vector_b ?
          vector_b_byte(word_index*64 + byte_index) :
          vector_a_byte(word_index*64 + byte_index);
      vector_word = value;
    end
  endfunction

  task automatic command_a(
    input logic [3:0] opcode,
    input logic [5:0] index,
    input logic [15:0] tag,
    input logic [511:0] data,
    input logic [3:0] expected_code
  );
    integer timeout;
    begin
      while (!req_ready_a) @(posedge txclk);
      @(negedge txclk);
      req_toggle_a = ~req_toggle_a;
      req_opcode_a = opcode;
      req_index_a = index;
      req_tag_a = tag;
      req_data_a = data;
      req_valid_a = 1'b1;
      @(negedge txclk);
      req_valid_a = 1'b0;
      timeout = 0;
      while (!rsp_valid_a && timeout < 100) begin
        @(posedge txclk);
        timeout = timeout + 1;
      end
      if (!rsp_valid_a || rsp_toggle_a != req_toggle_a ||
          rsp_code_a != expected_code) begin
        $display("TB_FINITE_FAIL=A_RESPONSE opcode=%0d code=%0d timeout=%0d",
                 opcode, rsp_code_a, timeout);
        $fatal(1);
      end
      // Model the real XPM source-side acknowledge: it rises only after the
      // response is valid and returns low before another request is issued.
      @(negedge txclk);
      rsp_ready_a = 1'b1;
      @(negedge txclk);
      rsp_ready_a = 1'b0;
    end
  endtask

  task automatic command_b(
    input logic [3:0] opcode,
    input logic [5:0] index,
    input logic [15:0] tag,
    input logic [511:0] data,
    input logic [3:0] expected_code
  );
    integer timeout;
    begin
      while (!req_ready_b) @(posedge txclk);
      @(negedge txclk);
      req_toggle_b = ~req_toggle_b;
      req_opcode_b = opcode;
      req_index_b = index;
      req_tag_b = tag;
      req_data_b = data;
      req_valid_b = 1'b1;
      @(negedge txclk);
      req_valid_b = 1'b0;
      timeout = 0;
      while (!rsp_valid_b && timeout < 100) begin
        @(posedge txclk);
        timeout = timeout + 1;
      end
      if (!rsp_valid_b || rsp_toggle_b != req_toggle_b ||
          rsp_code_b != expected_code) begin
        $display("TB_FINITE_FAIL=B_RESPONSE opcode=%0d code=%0d timeout=%0d",
                 opcode, rsp_code_b, timeout);
        $fatal(1);
      end
      @(negedge txclk);
      rsp_ready_b = 1'b1;
      @(negedge txclk);
      rsp_ready_b = 1'b0;
    end
  endtask

  // Present one exact 4096-byte A vector on RX B with SOP starting on any
  // physical LBUS segment.  Segments before SOP model the tail of a prior
  // packet in the same cycle.  Non-EOP MTY/ERR values are intentionally
  // nonzero because PG203 declares them invalid/don't-care away from EOP.
  task automatic drive_offset_packet_b(input integer sop_offset);
    integer cycle_index;
    integer physical_segment;
    integer packet_segment;
    logic [511:0] packet_word;
    begin
      cycle_index = 0;
      packet_segment = 0;
      rx_override_b = 1'b1;
      while (packet_segment < 256) begin
        @(negedge txclk);
        rx_override_data_b = 512'b0;
        rx_override_ena_b = 4'b0;
        rx_override_sop_b = 4'b0;
        rx_override_eop_b = 4'b0;
        rx_override_mty_b = 16'hAAAA;
        rx_override_err_b = 4'hF;
        for (physical_segment = 0; physical_segment < 4;
             physical_segment = physical_segment + 1) begin
          if (cycle_index == 0 && physical_segment < sop_offset) begin
            rx_override_ena_b[physical_segment] = 1'b1;
            if (physical_segment == sop_offset - 1) begin
              rx_override_eop_b[physical_segment] = 1'b1;
              rx_override_mty_b[physical_segment*4 +: 4] = 4'd0;
              rx_override_err_b[physical_segment] = 1'b0;
            end
          end else if (packet_segment < 256) begin
            packet_word = vector_word(1'b0, packet_segment / 4);
            rx_override_data_b[physical_segment*128 +: 128] =
              packet_word[(packet_segment % 4)*128 +: 128];
            rx_override_ena_b[physical_segment] = 1'b1;
            if (packet_segment == 0)
              rx_override_sop_b[physical_segment] = 1'b1;
            if (packet_segment == 255) begin
              rx_override_eop_b[physical_segment] = 1'b1;
              rx_override_mty_b[physical_segment*4 +: 4] = 4'd0;
              rx_override_err_b[physical_segment] = 1'b0;
            end
            packet_segment = packet_segment + 1;
          end
        end
        cycle_index = cycle_index + 1;
        if (cycle_index == 1) begin
          // RX ENA qualifies all other RX LBUS controls.  Model the hardware
          // backpressure case where the first in-frame gap retains arbitrary
          // SOP/EOP/MTY/ERR values; none may advance or reject the frame.
          @(negedge txclk);
          rx_override_data_b = {16{32'hCAFE_F00D}};
          rx_override_ena_b = 4'b0000;
          rx_override_sop_b = 4'b1010;
          rx_override_eop_b = 4'b0101;
          rx_override_mty_b = 16'h5AA5;
          rx_override_err_b = 4'b1111;
        end
      end
      @(negedge txclk);
      rx_override_b = 1'b0;
      rx_override_data_b = 512'b0;
      rx_override_ena_b = 4'b0;
      rx_override_sop_b = 4'b0;
      rx_override_eop_b = 4'b0;
      rx_override_mty_b = 16'b0;
      rx_override_err_b = 4'b0;
    end
  endtask

  task automatic bridge_command(
    input logic [3:0] opcode,
    input logic [5:0] index,
    input logic [511:0] data,
    input logic [3:0] expected_code
  );
    logic expected_toggle;
    integer timeout;
    begin
      expected_toggle = ~bridge_request[0];
      @(negedge mgmt_clk);
      bridge_source = data;
      bridge_request = {5'b0, 16'h55AA, index, opcode, expected_toggle};
      timeout = 0;
      while ((bridge_status[0] != expected_toggle ||
              bridge_status[121:118] != expected_code) && timeout < 300) begin
        @(posedge mgmt_clk);
        timeout = timeout + 1;
      end
      if (timeout >= 300) begin
        $display("TB_FINITE_FAIL=BRIDGE_RESPONSE opcode=%0d status=%h",
                 opcode, bridge_status);
        $fatal(1);
      end
    end
  endtask

  always @(posedge txclk) begin
    if (|link_ena_a && |link_ena_b)
      overlap_cycles <= overlap_cycles + 1;
  end

  integer word_index;
  integer offset_index;
  integer timeout;
  logic [511:0] read_value;
  initial begin
    req_valid_a = 1'b0;
    req_valid_b = 1'b0;
    req_toggle_a = 1'b0;
    req_toggle_b = 1'b0;
    req_opcode_a = 4'b0;
    req_opcode_b = 4'b0;
    req_index_a = 6'b0;
    req_index_b = 6'b0;
    req_tag_a = 16'b0;
    req_tag_b = 16'b0;
    req_data_a = 512'b0;
    req_data_b = 512'b0;
    vendor_ena_a = 4'b0;
    vendor_ena_b = 4'b0;
    vendor_eop_a = 4'b0;
    vendor_eop_b = 4'b0;

    repeat (8) @(posedge txclk);
    reset = 1'b0;
    repeat (4) @(posedge txclk);

    command_a(OP_CLEAR, 0, 0, 0, 0);
    command_b(OP_CLEAR, 0, 0, 0, 0);
    command_a(OP_LOAD, 6'd1, 0, vector_word(1'b0, 1), 4'd3);
    command_a(OP_CLEAR, 0, 0, 0, 0);

    for (word_index = 0; word_index < 64; word_index = word_index + 1) begin
      command_a(OP_LOAD, word_index[5:0], 0,
                vector_word(1'b0, word_index), 0);
      command_b(OP_LOAD, word_index[5:0], 0,
                vector_word(1'b1, word_index), 0);
    end

    // A must not switch on an EOP followed by active segments from the next
    // packed packet, nor on an ENA-low backpressure gap while that packet is
    // open.  It switches only after the highest active segment closes it.
    // B is already closed and idle.
    vendor_ena_a = 4'hf;
    vendor_eop_a = 4'h0;
    fork
      begin
        command_a(OP_QUIESCE, 0, 0, 0, 0);
      end
      begin
        repeat (5) @(negedge txclk);
        vendor_eop_a = 4'h1;
        @(negedge txclk);
        vendor_ena_a = 4'h0;
        vendor_eop_a = 4'h0;
        repeat (2) @(negedge txclk);
        if (select_a) begin
          $display("TB_FINITE_FAIL=PACKED_EOP_OR_OPEN_GAP_TAKEOVER");
          $fatal(1);
        end
        vendor_ena_a = 4'hf;
        repeat (2) @(negedge txclk);
        vendor_eop_a = 4'h8;
        @(negedge txclk);
        vendor_ena_a = 4'h0;
        vendor_eop_a = 4'h0;
      end
    join
    command_b(OP_QUIESCE, 0, 0, 0, 0);
    if (!select_a || !select_b) begin
      $display("TB_FINITE_FAIL=PACKET_BOUNDARY_TAKEOVER");
      $fatal(1);
    end

    repeat (8) @(posedge txclk);
    command_b(OP_ARM_FOLLOW, 0, 16'hB002, 0, 0);

    // Model the continuous-source takeover seen on hardware: an old non-SOP
    // transfer and delayed packet-statistics pulses can arrive after ARM but
    // before the finite SOP.  They are not owned by the finite transaction and
    // must neither reject it nor contaminate its telemetry.
    @(negedge txclk);
    rx_override_b = 1'b1;
    rx_override_data_b = {16{32'hDEAD_BEEF}};
    rx_override_ena_b = 4'hf;
    rx_override_sop_b = 4'h0;
    rx_override_eop_b = 4'h8;
    rx_override_mty_b = 16'h0000;
    rx_override_err_b = 4'h0;
    rx_fcs_error_b = 1'b1;
    rx_fec_corrected_b = 1'b1;
    rx_fec_uncorrectable_b = 1'b1;
    @(negedge txclk);
    rx_override_b = 1'b0;
    rx_fcs_error_b = 1'b0;
    rx_fec_corrected_b = 1'b0;
    rx_fec_uncorrectable_b = 1'b0;
    repeat (8) @(posedge txclk);
    if (live_status_b[65:63] != 3'd1 || live_status_b[22] ||
        live_status_b[25] || live_status_b[26] || live_status_b[27] ||
        live_status_b[41:35] != 7'd0) begin
      $display("TB_FINITE_FAIL=TAKEOVER_RESIDUE_ATTRIBUTED status=%h",
               live_status_b);
      $fatal(1);
    end

    command_a(OP_ARM_INIT, 0, 16'hA001, 0, 0);
    command_a(OP_START, 0, 16'hA001, 0, 0);

    // Reproduce the hardware falsifier: ready falls while both finite frames
    // are active.  Per PG203 the word present on the falling-ready cycle is
    // consumed once.  The engine must then withdraw ENA through a registered
    // HALT and resume with the next word, never replaying the prior data/SOP.
    wait ((|tx_ena_a) && (|tx_ena_b) &&
          live_status_a[34:28] >= 7'd8 && live_status_b[34:28] >= 7'd8);
    @(negedge txclk);
    begin : backpressure_check
      logic [511:0] held_data_a, held_data_b;
      logic [511:0] resume_data_a, resume_data_b;
      logic [3:0] held_sop_a, held_sop_b, held_eop_a, held_eop_b;
      logic [6:0] count_before_a, count_before_b;
      held_data_a = tx_data_a;
      held_data_b = tx_data_b;
      held_sop_a = tx_sop_a;
      held_sop_b = tx_sop_b;
      held_eop_a = tx_eop_a;
      held_eop_b = tx_eop_b;
      count_before_a = live_status_a[34:28];
      count_before_b = live_status_b[34:28];
      tx_rdy_a = 1'b0;
      tx_rdy_b = 1'b0;
      @(posedge txclk);
      @(negedge txclk);
      if (tx_ena_a != 4'b0 || tx_ena_b != 4'b0 ||
          tx_sop_a != 4'b0 || tx_sop_b != 4'b0 ||
          tx_eop_a != 4'b0 || tx_eop_b != 4'b0 ||
          live_status_a[34:28] != count_before_a + 1'b1 ||
          live_status_b[34:28] != count_before_b + 1'b1 ||
          tx_data_a === held_data_a || tx_data_b === held_data_b) begin
        $display("TB_FINITE_FAIL=CMAC_HALT_WITHDRAW A=%h/%h/%h B=%h/%h/%h",
                 tx_ena_a, tx_sop_a, tx_eop_a,
                 tx_ena_b, tx_sop_b, tx_eop_b);
        $fatal(1);
      end
      resume_data_a = tx_data_a;
      resume_data_b = tx_data_b;
      tx_rdy_a = 1'b1;
      tx_rdy_b = 1'b1;
      wait ((|tx_ena_a) && (|tx_ena_b));
      if (tx_data_a !== resume_data_a || tx_data_b !== resume_data_b ||
          tx_data_a === held_data_a || tx_data_b === held_data_b ||
          tx_sop_a !== 4'b0 || tx_sop_b !== 4'b0 ||
          tx_eop_a !== 4'b0 || tx_eop_b !== 4'b0) begin
        $display("TB_FINITE_FAIL=CMAC_HALT_RESUME_REPLAY");
        $fatal(1);
      end
      backpressure_exercised = 1'b1;
    end

    timeout = 0;
    while (!(live_status_a[19] && live_status_a[21] &&
             live_status_b[19] && live_status_b[21]) && timeout < 300) begin
      @(posedge txclk);
      timeout = timeout + 1;
    end
    if (timeout >= 300 || overlap_cycles < 56 || !backpressure_exercised) begin
      $display("TB_FINITE_FAIL=FULL_DUPLEX_COMPLETE timeout=%0d overlap=%0d backpressure=%0d",
               timeout, overlap_cycles, backpressure_exercised);
      $fatal(1);
    end

    command_a(OP_STATUS, 0, 0, 0, 0);
    command_b(OP_STATUS, 0, 0, 0, 0);
    if (rsp_status_a[34:28] != 7'd64 || rsp_status_a[41:35] != 7'd64 ||
        rsp_status_b[34:28] != 7'd64 || rsp_status_b[41:35] != 7'd64 ||
        rsp_status_a[22] || rsp_status_a[24] || rsp_status_a[25] ||
        rsp_status_a[26] || rsp_status_b[22] || rsp_status_b[24] ||
        rsp_status_b[25] || rsp_status_b[26] ||
        !rsp_status_a[23] || !rsp_status_b[23]) begin
      $display("TB_FINITE_FAIL=STATUS A=%h B=%h", rsp_status_a, rsp_status_b);
      $fatal(1);
    end

    for (word_index = 0; word_index < 64; word_index = word_index + 1) begin
      command_a(OP_READ, word_index[5:0], 0, 0, 0);
      read_value = rsp_data_a;
      if (read_value !== vector_word(1'b1, word_index)) begin
        $display("TB_FINITE_FAIL=A_COMPARE word=%0d", word_index);
        $fatal(1);
      end
      command_b(OP_READ, word_index[5:0], 0, 0, 0);
      read_value = rsp_data_b;
      if (read_value !== vector_word(1'b0, word_index)) begin
        $display("TB_FINITE_FAIL=B_COMPARE word=%0d", word_index);
        $fatal(1);
      end
    end

    // RX packet boundaries are independent of 512-bit user-word boundaries.
    // Prove all four physical SOP segments reassemble to the same exact
    // 64-word vector, including an ENA-low cycle with invalid retained
    // controls and (for nonzero offsets) a prior EOP earlier in the first
    // cycle.
    for (offset_index = 0; offset_index < 4;
         offset_index = offset_index + 1) begin
      reset = 1'b1;
      rx_override_b = 1'b0;
      repeat (8) @(posedge txclk);
      reset = 1'b0;
      repeat (4) @(posedge txclk);
      for (word_index = 0; word_index < 64;
           word_index = word_index + 1)
        command_b(OP_LOAD, word_index[5:0], 0,
                  vector_word(1'b1, word_index), 0);
      command_b(OP_QUIESCE, 0, 0, 0, 0);
      command_b(OP_ARM_FOLLOW, 0, 16'hE100 + offset_index, 0, 0);
      drive_offset_packet_b(offset_index);
      timeout = 0;
      while (!(live_status_b[19] && live_status_b[21]) && timeout < 300) begin
        @(posedge txclk);
        timeout = timeout + 1;
      end
      if (timeout >= 300 || live_status_b[22] ||
          live_status_b[41:35] != 7'd64) begin
        $display("TB_FINITE_FAIL=SEGMENT_OFFSET_COMPLETE offset=%0d status=%h",
                 offset_index, live_status_b);
        $fatal(1);
      end
      for (word_index = 0; word_index < 64;
           word_index = word_index + 1) begin
        command_b(OP_READ, word_index[5:0], 0, 0, 0);
        if (rsp_data_b !== vector_word(1'b0, word_index)) begin
          $display("TB_FINITE_FAIL=SEGMENT_OFFSET_COMPARE offset=%0d word=%0d",
                   offset_index, word_index);
          $fatal(1);
        end
      end
    end

    // Reset into an independent transaction and prove that the aligned LBUS
    // rx_errout on the actual final transfer still rejects the finite frame.
    // This distinguishes the current-packet oracle from delayed statistics.
    reset = 1'b1;
    tx_rdy_a = 1'b1;
    tx_rdy_b = 1'b1;
    repeat (8) @(posedge txclk);
    reset = 1'b0;
    repeat (4) @(posedge txclk);
    for (word_index = 0; word_index < 64; word_index = word_index + 1) begin
      command_a(OP_LOAD, word_index[5:0], 0,
                vector_word(1'b0, word_index), 0);
      command_b(OP_LOAD, word_index[5:0], 0,
                vector_word(1'b1, word_index), 0);
    end
    command_a(OP_QUIESCE, 0, 0, 0, 0);
    command_b(OP_QUIESCE, 0, 0, 0, 0);
    command_b(OP_ARM_FOLLOW, 0, 16'hD004, 0, 0);
    command_a(OP_ARM_INIT, 0, 16'hC003, 0, 0);
    inject_terminal_rx_err_b = 1'b1;
    command_a(OP_START, 0, 16'hC003, 0, 0);
    timeout = 0;
    while (!(live_status_a[19] && live_status_a[21] &&
             live_status_b[19] && live_status_b[22]) && timeout < 300) begin
      @(posedge txclk);
      timeout = timeout + 1;
    end
    inject_terminal_rx_err_b = 1'b0;
    if (timeout >= 300 || live_status_b[41:35] != 7'd63 ||
        !live_status_b[25] || live_status_b[26]) begin
      $display("TB_FINITE_FAIL=ALIGNED_RX_ERR_NOT_REJECTED A=%h B=%h",
               live_status_a, live_status_b);
      $fatal(1);
    end
    if (live_status_b[71:70] != 2'd3 ||
        live_status_b[75:72] != 4'hf ||
        live_status_b[83:80] != 4'h8 ||
        live_status_b[103:100] != 4'h8) begin
      $display("TB_FINITE_FAIL=REJECT_DIAGNOSTIC status=%h", live_status_b);
      $fatal(1);
    end

    // Independent bridge smoke: one CLEAR and one 512-bit LOAD cross both
    // asynchronous handshake directions with exact response toggles.
    repeat (6) @(posedge mgmt_clk);
    bridge_mgmt_reset = 1'b0;
    bridge_tx_reset = 1'b0;
    repeat (12) @(posedge mgmt_clk);
    bridge_command(OP_CLEAR, 0, 0, 0);
    bridge_command(OP_LOAD, 0, vector_word(1'b0, 0), 0);
    if (bridge_status[7:1] != 7'd1) begin
      $display("TB_FINITE_FAIL=BRIDGE_LOAD_STATUS status=%h", bridge_status);
      $fatal(1);
    end

    $display("FINITE_STREAM_FACTS=bytes_each:4096 words_each:64 overlap_cycles:%0d full_compare_both:1 packet_boundary_takeover:1 packed_eop_open_packet_not_taken:1 open_packet_idle_gap_not_taken:1 takeover_residue_ignored:1 segmented_sop_offsets_0_1_2_3:1 non_eop_mty_err_ignored:1 aligned_rx_err_reject:1 reject_cycle_diagnostic:1 xpm_handshake:1 anti_oracle:1 cmac_backpressure_halt_resume:1 falling_ready_cycle_advanced_once:1 no_word_replay:1 accepted_cycle_bubble_free:1",
             overlap_cycles);
    $display("TB_FINITE_STREAM_ENGINE=PASS");
    $finish;
  end
endmodule

`default_nettype wire
