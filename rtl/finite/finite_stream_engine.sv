`timescale 1ns/1ps
`default_nettype none

// Finite-exact CMAC client. TX LBUS/source RAM are wholly TXUSRCLK2-owned;
// RX LBUS/capture RAM are wholly RXUSRCLK2-owned. Only atomic XPM handshakes
// and one follower-start toggle cross between the two user-clock domains.
// No expected vector or DUT-side payload comparator exists here.
module finite_stream_engine (
  input  wire          txusrclk2_i,
  input  wire          tx_reset_i,
  input  wire          rxusrclk2_i,
  input  wire          rx_reset_i,
  input  wire          request_valid_i,
  output wire          request_ready_o,
  input  wire          request_toggle_i,
  input  wire [3:0]    request_opcode_i,
  input  wire [5:0]    request_word_index_i,
  input  wire [15:0]   request_tag_i,
  input  wire [511:0]  request_data_i,
  output logic         response_valid_o,
  input  wire          response_ready_i,
  output logic         response_toggle_o,
  output logic [3:0]   response_code_o,
  output logic [5:0]   response_word_index_o,
  output logic [511:0] response_data_o,
  output logic [127:0] response_status_o,
  input  wire [3:0]    vendor_tx_ena_i,
  input  wire [3:0]    vendor_tx_eop_i,
  input  wire          cmac_tx_rdy_i,
  output logic         finite_select_o,
  output logic [511:0] finite_tx_data_o,
  output logic [3:0]   finite_tx_ena_o,
  output logic [3:0]   finite_tx_sop_o,
  output logic [3:0]   finite_tx_eop_o,
  output logic [15:0]  finite_tx_mty_o,
  output logic [3:0]   finite_tx_err_o,
  input  wire [511:0]  rx_data_i,
  input  wire [3:0]    rx_ena_i,
  input  wire [3:0]    rx_sop_i,
  input  wire [3:0]    rx_eop_i,
  input  wire [15:0]   rx_mty_i,
  input  wire [3:0]    rx_err_i,
  input  wire          rx_fcs_error_i,
  input  wire          rx_fec_corrected_i,
  input  wire          rx_fec_uncorrectable_i,
  output logic [127:0] live_status_o
);
  localparam logic [3:0] OP_CLEAR       = 4'd1;
  localparam logic [3:0] OP_LOAD        = 4'd2;
  localparam logic [3:0] OP_QUIESCE     = 4'd3;
  localparam logic [3:0] OP_ARM_FOLLOW  = 4'd4;
  localparam logic [3:0] OP_ARM_INIT    = 4'd5;
  localparam logic [3:0] OP_START       = 4'd6;
  localparam logic [3:0] OP_READ        = 4'd7;
  localparam logic [3:0] OP_STATUS      = 4'd8;
  localparam logic [3:0] OP_ABORT       = 4'd9;
  localparam logic [3:0] RSP_OK           = 4'd0;
  localparam logic [3:0] RSP_BAD_OPCODE   = 4'd1;
  localparam logic [3:0] RSP_PRECONDITION = 4'd2;
  localparam logic [3:0] RSP_SEQUENCE     = 4'd3;
  localparam logic [3:0] RSP_RANGE        = 4'd4;

  typedef enum logic [1:0] {
    TX_IDLE, TX_SEND, TX_DONE, TX_ABORTED
  } tx_state_t;
  typedef enum logic [2:0] {
    RX_IDLE     = 3'd0,
    RX_WAIT_SOP = 3'd1,
    RX_ACTIVE   = 3'd2,
    RX_DONE     = 3'd3,
    RX_REJECTED = 3'd4,
    RX_COMMIT   = 3'd5
  } rx_state_t;

  // Exactly one word is written/read per user clock.  The memories are
  // explicit XPMs because a 512-bit-wide inferred array otherwise unfolds
  // into registers and a 64:1 mux tree instead of block RAM on both targets.
  wire [0:0] source_mem_we;
  logic [5:0] source_mem_read_addr;
  wire [511:0] source_mem_read_data;
  wire [0:0] capture_mem_we;
  wire [5:0] capture_mem_write_addr;
  wire [511:0] capture_mem_write_data;
  wire [511:0] capture_mem_read_data;

  tx_state_t tx_state;
  rx_state_t rx_state_rx;
  rx_state_t rx_state_tx;
  logic [6:0] source_loaded_words;
  logic [6:0] capture_words_tx;
  logic [6:0] tx_accepted_cycles;
  logic [6:0] rx_accepted_cycles_tx;
  logic [5:0] tx_word_index;
  logic armed;
  logic follower;
  logic [15:0] transaction_tag;
  logic tx_drive_enable;
  logic tx_ready_loss_sticky;
  logic protocol_error_sticky;
  logic fcs_error_sticky_tx;
  logic fec_corrected_sticky_tx;
  logic fec_uncorrectable_sticky_tx;
  logic rx_rejected_sticky_tx;
  logic [1:0] rx_reject_reason_tx;
  logic [3:0] rx_reject_ena_tx;
  logic [3:0] rx_reject_sop_tx;
  logic [3:0] rx_reject_eop_tx;
  logic [15:0] rx_reject_mty_tx;
  logic [3:0] rx_reject_err_tx;
  logic [1:0] rx_reject_offset_tx;
  logic quiesce_wait;
  logic vendor_packet_open;
  logic vendor_packet_open_after_cycle;
  logic vendor_cycle_closes_packet;
  logic vendor_quiesce_safe;
  logic [1:0] read_wait;
  logic [5:0] capture_read_addr;

  logic completion_pending;
  logic [3:0] completion_code;
  logic [5:0] completion_word_index;
  logic [511:0] completion_data;
  logic completion_toggle;

  logic arm_send_tx;
  wire arm_ack_tx;
  logic arm_wait_tx;
  logic arm_drain_tx;
  logic [16:0] arm_bundle_tx;
  wire [16:0] arm_bundle_rx;
  wire arm_valid_rx;

  // RX result bundle preserves the accepted result in bits [10:0] and carries
  // the exact rejected LBUS control cycle above it for a hardware falsifier.
  logic rx_result_send_rx;
  wire rx_result_ack_rx;
  logic [46:0] rx_result_bundle_rx;
  wire [46:0] rx_result_bundle_tx;
  wire rx_result_valid_tx;

  logic rx_start_toggle_rx;
  wire rx_start_toggle_tx;
  logic rx_start_toggle_seen_tx;
  logic [6:0] capture_words_rx;
  logic [1:0] rx_sop_offset_rx;
  logic [511:0] rx_previous_cycle_data_rx;
  logic capture_write_valid_rx;
  logic [5:0] capture_write_addr_rx;
  logic [511:0] capture_write_data_rx;
  logic rx_follower_rx;
  logic rx_rejected_sticky_rx;
  logic fcs_error_sticky_rx;
  logic fec_corrected_sticky_rx;
  logic fec_uncorrectable_sticky_rx;
  logic [1:0] rx_detected_sop_offset;
  logic rx_detected_sop_onehot;
  logic [511:0] rx_aligned_word;

  xpm_cdc_handshake #(
    .DEST_EXT_HSK(0), .DEST_SYNC_FF(4), .INIT_SYNC_FF(1),
    .SIM_ASSERT_CHK(1), .SRC_SYNC_FF(4), .WIDTH(17)
  ) arm_tx_to_rx_i (
    .src_clk(txusrclk2_i), .src_in(arm_bundle_tx),
    .src_send(arm_send_tx), .src_rcv(arm_ack_tx),
    .dest_clk(rxusrclk2_i), .dest_out(arm_bundle_rx),
    .dest_req(arm_valid_rx), .dest_ack(1'b0)
  );

  xpm_cdc_handshake #(
    .DEST_EXT_HSK(0), .DEST_SYNC_FF(4), .INIT_SYNC_FF(1),
    .SIM_ASSERT_CHK(1), .SRC_SYNC_FF(4), .WIDTH(47)
  ) result_rx_to_tx_i (
    .src_clk(rxusrclk2_i), .src_in(rx_result_bundle_rx),
    .src_send(rx_result_send_rx), .src_rcv(rx_result_ack_rx),
    .dest_clk(txusrclk2_i), .dest_out(rx_result_bundle_tx),
    .dest_req(rx_result_valid_tx), .dest_ack(1'b0)
  );

  xpm_cdc_single #(
    .DEST_SYNC_FF(4), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(1),
    .SRC_INPUT_REG(1)
  ) follower_start_rx_to_tx_i (
    .src_clk(rxusrclk2_i), .src_in(rx_start_toggle_rx),
    .dest_clk(txusrclk2_i), .dest_out(rx_start_toggle_tx)
  );

  wire source_mem_write_accept = request_valid_i && request_ready_o &&
    request_opcode_i == OP_LOAD && !finite_select_o && !armed &&
    tx_state == TX_IDLE && rx_state_tx == RX_IDLE &&
    source_loaded_words < 7'd64 &&
    request_word_index_i == source_loaded_words[5:0];
  assign source_mem_we = {source_mem_write_accept};

  assign capture_mem_we = {capture_write_valid_rx};
  assign capture_mem_write_addr = capture_write_addr_rx;
  assign capture_mem_write_data = capture_write_data_rx;

  // Find an enabled SOP without assuming segment zero.  More than one SOP is
  // outside this single-frame contract and therefore is not one-hot.
  always_comb begin
    rx_detected_sop_offset = 2'd0;
    rx_detected_sop_onehot = 1'b1;
    case (rx_ena_i & rx_sop_i)
      4'b0001: rx_detected_sop_offset = 2'd0;
      4'b0010: rx_detected_sop_offset = 2'd1;
      4'b0100: rx_detected_sop_offset = 2'd2;
      4'b1000: rx_detected_sop_offset = 2'd3;
      default: rx_detected_sop_onehot = 1'b0;
    endcase
  end

  // One fixed 4:1 alignment mux replaces the prior unrolled segment walker.
  // Its output is registered before the capture BRAM, breaking the measured
  // CMAC-control-to-BRAM 10/11-LUT path at 322.265625 MHz.
  always_comb begin
    case (rx_sop_offset_rx)
      2'd0: rx_aligned_word = rx_data_i;
      2'd1: rx_aligned_word =
        {rx_data_i[127:0], rx_previous_cycle_data_rx[511:128]};
      2'd2: rx_aligned_word =
        {rx_data_i[255:0], rx_previous_cycle_data_rx[511:256]};
      default: rx_aligned_word =
        {rx_data_i[383:0], rx_previous_cycle_data_rx[511:384]};
    endcase
  end

  function automatic logic li7_rx_start_cycle_valid(
    input logic [1:0] offset,
    input logic [3:0] ena,
    input logic [3:0] sop,
    input logic [3:0] eop
  );
    begin
      case (offset)
        2'd0: li7_rx_start_cycle_valid =
          (ena == 4'b1111 && sop == 4'b0001 && eop == 4'b0000);
        2'd1: li7_rx_start_cycle_valid =
          (ena[3:1] == 3'b111 && sop[3:1] == 3'b001 &&
           eop[3:1] == 3'b000);
        2'd2: li7_rx_start_cycle_valid =
          (ena[3:2] == 2'b11 && sop[3:2] == 2'b01 &&
           eop[3:2] == 2'b00);
        default: li7_rx_start_cycle_valid =
          (ena[3] && sop[3] && !eop[3]);
      endcase
    end
  endfunction

  function automatic logic li7_rx_final_cycle_valid(
    input logic [1:0] offset,
    input logic [3:0] ena,
    input logic [3:0] sop,
    input logic [3:0] eop,
    input logic [15:0] mty,
    input logic [3:0] err
  );
    begin
      case (offset)
        2'd0: li7_rx_final_cycle_valid =
          (ena == 4'b1111 && sop == 4'b0000 && eop == 4'b1000 &&
           mty[15:12] == 4'd0 && !err[3]);
        2'd1: li7_rx_final_cycle_valid =
          (ena[0] && !sop[0] && eop[0] &&
           mty[3:0] == 4'd0 && !err[0]);
        2'd2: li7_rx_final_cycle_valid =
          (ena[1:0] == 2'b11 && sop[1:0] == 2'b00 &&
           eop[1:0] == 2'b10 && mty[7:4] == 4'd0 && !err[1]);
        default: li7_rx_final_cycle_valid =
          (ena[2:0] == 3'b111 && sop[2:0] == 3'b000 &&
           eop[2:0] == 3'b100 && mty[11:8] == 4'd0 && !err[2]);
      endcase
    end
  endfunction

  wire finite_tx_cycle_present = tx_state == TX_SEND && tx_drive_enable;
  // PG203 defines tx_rdyout as an advance backpressure warning, not a
  // same-cycle valid/ready handshake.  A cycle with ENA asserted is consumed
  // even when tx_rdyout has just fallen; the source then has up to four
  // cycles to stop.  Count and advance every presented cycle exactly once so
  // the first word after a ready transition is never replayed (replaying SOP
  // corrupts the frame).  tx_drive_enable below supplies the registered HALT.
  wire finite_tx_cycle_accept = finite_tx_cycle_present;

  // Keep word zero prefetched while idle.  During each presented TX cycle,
  // present the next address before the edge so READ_LATENCY_B=1 advances
  // the 512-bit LBUS word without inserting an accepted-cycle bubble.  If
  // ready falls, that currently presented word is still consumed once; the
  // registered HALT exposes the already-prefetched next word only after ready
  // returns.
  always_comb begin
    source_mem_read_addr = 6'd0;
    if (tx_state == TX_SEND) begin
      source_mem_read_addr = tx_word_index;
      if (finite_tx_cycle_accept && tx_word_index != 6'd63)
        source_mem_read_addr = tx_word_index + 1'b1;
    end
  end

  xpm_memory_sdpram #(
    .ADDR_WIDTH_A(6),
    .ADDR_WIDTH_B(6),
    .AUTO_SLEEP_TIME(0),
    .BYTE_WRITE_WIDTH_A(512),
    .CASCADE_HEIGHT(0),
    .CLOCKING_MODE("common_clock"),
    .ECC_MODE("no_ecc"),
    .MEMORY_INIT_FILE("none"),
    .MEMORY_INIT_PARAM("0"),
    .MEMORY_OPTIMIZATION("false"),
    .MEMORY_PRIMITIVE("block"),
    .MEMORY_SIZE(32768),
    .MESSAGE_CONTROL(0),
    .READ_DATA_WIDTH_B(512),
    .READ_LATENCY_B(1),
    .READ_RESET_VALUE_B("0"),
    .RST_MODE_B("SYNC"),
    .SIM_ASSERT_CHK(1),
    .USE_EMBEDDED_CONSTRAINT(0),
    .USE_MEM_INIT(0),
    .WAKEUP_TIME("disable_sleep"),
    .WRITE_DATA_WIDTH_A(512),
    .WRITE_MODE_B("no_change")
  ) source_mem_i (
    .clka(txusrclk2_i),
    .clkb(txusrclk2_i),
    .addra(request_word_index_i),
    .addrb(source_mem_read_addr),
    .dina(request_data_i),
    .doutb(source_mem_read_data),
    .ena(1'b1),
    .enb(1'b1),
    .injectdbiterra(1'b0),
    .injectsbiterra(1'b0),
    .regceb(1'b1),
    .rstb(tx_reset_i),
    .sleep(1'b0),
    .wea(source_mem_we),
    .dbiterrb(),
    .sbiterrb()
  );

  xpm_memory_sdpram #(
    .ADDR_WIDTH_A(6),
    .ADDR_WIDTH_B(6),
    .AUTO_SLEEP_TIME(0),
    .BYTE_WRITE_WIDTH_A(512),
    .CASCADE_HEIGHT(0),
    .CLOCKING_MODE("independent_clock"),
    .ECC_MODE("no_ecc"),
    .MEMORY_INIT_FILE("none"),
    .MEMORY_INIT_PARAM("0"),
    .MEMORY_OPTIMIZATION("false"),
    .MEMORY_PRIMITIVE("block"),
    .MEMORY_SIZE(32768),
    .MESSAGE_CONTROL(0),
    .READ_DATA_WIDTH_B(512),
    .READ_LATENCY_B(1),
    .READ_RESET_VALUE_B("0"),
    .RST_MODE_B("SYNC"),
    .SIM_ASSERT_CHK(1),
    .USE_EMBEDDED_CONSTRAINT(0),
    .USE_MEM_INIT(0),
    .WAKEUP_TIME("disable_sleep"),
    .WRITE_DATA_WIDTH_A(512),
    .WRITE_MODE_B("no_change")
  ) capture_mem_i (
    .clka(rxusrclk2_i),
    .clkb(txusrclk2_i),
    .addra(capture_mem_write_addr),
    .addrb(capture_read_addr),
    .dina(capture_mem_write_data),
    .doutb(capture_mem_read_data),
    .ena(1'b1),
    .enb(1'b1),
    .injectdbiterra(1'b0),
    .injectsbiterra(1'b0),
    .regceb(1'b1),
    .rstb(tx_reset_i),
    .sleep(1'b0),
    .wea(capture_mem_we),
    .dbiterrb(),
    .sbiterrb()
  );

  wire vendor_idle = vendor_tx_ena_i == 4'b0000;
  // A segmented LBUS cycle can end one packet and begin the next in a later
  // segment.  Switching the mux on "any EOP" truncates that newly opened
  // packet.  Track the packet-open state at the end of the presented cycle and
  // permit takeover only when its highest active segment is an EOP (or when a
  // genuinely closed stream is idle).  An ENA-low backpressure gap while a
  // packet is open is deliberately not a boundary.
  always_comb begin
    vendor_cycle_closes_packet = 1'b0;
    if (vendor_tx_ena_i[3])
      vendor_cycle_closes_packet = vendor_tx_eop_i[3];
    else if (vendor_tx_ena_i[2])
      vendor_cycle_closes_packet = vendor_tx_eop_i[2];
    else if (vendor_tx_ena_i[1])
      vendor_cycle_closes_packet = vendor_tx_eop_i[1];
    else if (vendor_tx_ena_i[0])
      vendor_cycle_closes_packet = vendor_tx_eop_i[0];

    vendor_packet_open_after_cycle = vendor_packet_open;
    if (|vendor_tx_ena_i)
      vendor_packet_open_after_cycle = !vendor_cycle_closes_packet;

    vendor_quiesce_safe = !vendor_packet_open_after_cycle &&
      (vendor_idle || vendor_cycle_closes_packet);
  end
  wire tx_active = tx_state == TX_SEND;
  wire tx_done = tx_state == TX_DONE;
  wire rx_active = rx_state_tx == RX_ACTIVE;
  wire rx_committed = rx_state_tx == RX_DONE;

  assign request_ready_o = !completion_pending && !response_valid_o &&
                           !response_ready_i && !quiesce_wait &&
                           (read_wait == 2'd0) && !arm_wait_tx &&
                           !arm_drain_tx;

  always_comb begin
    finite_tx_data_o = source_mem_read_data;
    finite_tx_ena_o = 4'b0000;
    finite_tx_sop_o = 4'b0000;
    finite_tx_eop_o = 4'b0000;
    finite_tx_mty_o = 16'h0000;
    finite_tx_err_o = 4'b0000;
    if (finite_tx_cycle_present) begin
      finite_tx_ena_o = 4'hf;
      finite_tx_sop_o = (tx_word_index == 6'd0) ? 4'h1 : 4'h0;
      finite_tx_eop_o = (tx_word_index == 6'd63) ? 4'h8 : 4'h0;
    end
  end

  always_comb begin
    live_status_o = 128'b0;
    live_status_o[7:1] = source_loaded_words;
    live_status_o[14:8] = capture_words_tx;
    live_status_o[15] = finite_select_o;
    live_status_o[16] = armed;
    live_status_o[17] = follower;
    live_status_o[18] = tx_active;
    live_status_o[19] = tx_done;
    live_status_o[20] = rx_active;
    live_status_o[21] = rx_committed;
    live_status_o[22] = rx_rejected_sticky_tx;
    live_status_o[23] = tx_ready_loss_sticky;
    live_status_o[24] = protocol_error_sticky;
    live_status_o[25] = fcs_error_sticky_tx;
    live_status_o[26] = fec_uncorrectable_sticky_tx;
    live_status_o[27] = fec_corrected_sticky_tx;
    live_status_o[34:28] = tx_accepted_cycles;
    live_status_o[41:35] = rx_accepted_cycles_tx;
    live_status_o[57:42] = transaction_tag;
    live_status_o[58] = vendor_idle;
    live_status_o[59] = cmac_tx_rdy_i;
    live_status_o[60] = source_loaded_words == 7'd64;
    live_status_o[62:61] = tx_state;
    live_status_o[65:63] = rx_state_tx;
    live_status_o[66] = quiesce_wait;
    live_status_o[67] = request_ready_o;
    live_status_o[68] = arm_wait_tx || arm_drain_tx;
    live_status_o[69] = tx_drive_enable;
    live_status_o[71:70] = rx_reject_reason_tx;
    live_status_o[75:72] = rx_reject_ena_tx;
    live_status_o[79:76] = rx_reject_sop_tx;
    live_status_o[83:80] = rx_reject_eop_tx;
    live_status_o[99:84] = rx_reject_mty_tx;
    live_status_o[103:100] = rx_reject_err_tx;
    live_status_o[105:104] = rx_reject_offset_tx;
  end

  always_ff @(posedge txusrclk2_i) begin
    if (tx_reset_i) begin
      tx_state <= TX_IDLE;
      rx_state_tx <= RX_IDLE;
      source_loaded_words <= 7'd0;
      capture_words_tx <= 7'd0;
      tx_accepted_cycles <= 7'd0;
      rx_accepted_cycles_tx <= 7'd0;
      tx_word_index <= 6'd0;
      armed <= 1'b0;
      follower <= 1'b0;
      transaction_tag <= 16'b0;
      tx_drive_enable <= 1'b0;
      tx_ready_loss_sticky <= 1'b0;
      protocol_error_sticky <= 1'b0;
      fcs_error_sticky_tx <= 1'b0;
      fec_corrected_sticky_tx <= 1'b0;
      fec_uncorrectable_sticky_tx <= 1'b0;
      rx_rejected_sticky_tx <= 1'b0;
      rx_reject_reason_tx <= 2'b0;
      rx_reject_ena_tx <= 4'b0;
      rx_reject_sop_tx <= 4'b0;
      rx_reject_eop_tx <= 4'b0;
      rx_reject_mty_tx <= 16'b0;
      rx_reject_err_tx <= 4'b0;
      rx_reject_offset_tx <= 2'b0;
      finite_select_o <= 1'b0;
      quiesce_wait <= 1'b0;
      vendor_packet_open <= 1'b0;
      read_wait <= 2'd0;
      capture_read_addr <= 6'd0;
      completion_pending <= 1'b0;
      completion_code <= RSP_OK;
      completion_word_index <= 6'd0;
      completion_data <= 512'b0;
      completion_toggle <= 1'b0;
      response_valid_o <= 1'b0;
      response_toggle_o <= 1'b0;
      response_code_o <= RSP_OK;
      response_word_index_o <= 6'd0;
      response_data_o <= 512'b0;
      response_status_o <= 128'b0;
      arm_send_tx <= 1'b0;
      arm_wait_tx <= 1'b0;
      arm_drain_tx <= 1'b0;
      arm_bundle_tx <= 17'b0;
      rx_start_toggle_seen_tx <= 1'b0;
    end else begin
      if (!finite_select_o)
        vendor_packet_open <= vendor_packet_open_after_cycle;

      if (response_valid_o && response_ready_i)
        response_valid_o <= 1'b0;

      if (completion_pending && !response_valid_o && !response_ready_i) begin
        response_toggle_o <= completion_toggle;
        response_code_o <= completion_code;
        response_word_index_o <= completion_word_index;
        response_data_o <= completion_data;
        response_status_o <= live_status_o;
        response_valid_o <= 1'b1;
        completion_pending <= 1'b0;
      end

      if (arm_wait_tx && arm_ack_tx) begin
        arm_send_tx <= 1'b0;
        arm_wait_tx <= 1'b0;
        arm_drain_tx <= 1'b1;
        armed <= 1'b1;
        follower <= arm_bundle_tx[16];
        transaction_tag <= arm_bundle_tx[15:0];
        rx_state_tx <= RX_WAIT_SOP;
        rx_start_toggle_seen_tx <= rx_start_toggle_tx;
        completion_code <= RSP_OK;
        completion_word_index <= 6'd0;
        completion_data <= 512'b0;
        completion_pending <= 1'b1;
      end
      if (arm_drain_tx && !arm_ack_tx)
        arm_drain_tx <= 1'b0;

      if (rx_start_toggle_tx != rx_start_toggle_seen_tx) begin
        rx_start_toggle_seen_tx <= rx_start_toggle_tx;
        rx_state_tx <= RX_ACTIVE;
        if (armed && follower && tx_state == TX_IDLE) begin
          tx_word_index <= 6'd0;
          tx_drive_enable <= cmac_tx_rdy_i;
          tx_state <= TX_SEND;
        end
      end

      if (rx_result_valid_tx) begin
        capture_words_tx <= rx_result_bundle_tx[6:0];
        rx_accepted_cycles_tx <= rx_result_bundle_tx[6:0];
        rx_rejected_sticky_tx <= rx_result_bundle_tx[7];
        fcs_error_sticky_tx <= rx_result_bundle_tx[8];
        fec_uncorrectable_sticky_tx <= rx_result_bundle_tx[9];
        fec_corrected_sticky_tx <= rx_result_bundle_tx[10];
        rx_reject_reason_tx <= rx_result_bundle_tx[12:11];
        rx_reject_ena_tx <= rx_result_bundle_tx[16:13];
        rx_reject_sop_tx <= rx_result_bundle_tx[20:17];
        rx_reject_eop_tx <= rx_result_bundle_tx[24:21];
        rx_reject_mty_tx <= rx_result_bundle_tx[40:25];
        rx_reject_err_tx <= rx_result_bundle_tx[44:41];
        rx_reject_offset_tx <= rx_result_bundle_tx[46:45];
        rx_state_tx <= rx_result_bundle_tx[7] ? RX_REJECTED : RX_DONE;
      end

      if (quiesce_wait && vendor_quiesce_safe) begin
        finite_select_o <= 1'b1;
        quiesce_wait <= 1'b0;
        completion_code <= RSP_OK;
        completion_word_index <= 6'd0;
        completion_data <= 512'b0;
        completion_pending <= 1'b1;
      end

      if (read_wait == 2'd1) begin
        read_wait <= 2'd2;
      end else if (read_wait == 2'd2) begin
        completion_data <= capture_mem_read_data;
        completion_code <= RSP_OK;
        completion_word_index <= capture_read_addr;
        completion_pending <= 1'b1;
        read_wait <= 2'd0;
      end

      if (request_valid_i && !request_ready_o) begin
        protocol_error_sticky <= 1'b1;
      end else if (request_valid_i) begin
        completion_toggle <= request_toggle_i;
        completion_word_index <= request_word_index_i;
        completion_data <= 512'b0;
        case (request_opcode_i)
          OP_CLEAR: begin
            if (finite_select_o || armed || tx_active || rx_active) begin
              completion_code <= RSP_PRECONDITION;
            end else begin
              tx_state <= TX_IDLE;
              rx_state_tx <= RX_IDLE;
              source_loaded_words <= 7'd0;
              capture_words_tx <= 7'd0;
              tx_accepted_cycles <= 7'd0;
              rx_accepted_cycles_tx <= 7'd0;
              tx_drive_enable <= 1'b0;
              tx_ready_loss_sticky <= 1'b0;
              protocol_error_sticky <= 1'b0;
              fcs_error_sticky_tx <= 1'b0;
              fec_corrected_sticky_tx <= 1'b0;
              fec_uncorrectable_sticky_tx <= 1'b0;
              rx_rejected_sticky_tx <= 1'b0;
              rx_reject_reason_tx <= 2'b0;
              rx_reject_ena_tx <= 4'b0;
              rx_reject_sop_tx <= 4'b0;
              rx_reject_eop_tx <= 4'b0;
              rx_reject_mty_tx <= 16'b0;
              rx_reject_err_tx <= 4'b0;
              rx_reject_offset_tx <= 2'b0;
              follower <= 1'b0;
              transaction_tag <= 16'b0;
              completion_code <= RSP_OK;
            end
            completion_pending <= 1'b1;
          end

          OP_LOAD: begin
            if (finite_select_o || armed || tx_state != TX_IDLE ||
                rx_state_tx != RX_IDLE) begin
              completion_code <= RSP_PRECONDITION;
            end else if (source_loaded_words >= 7'd64) begin
              completion_code <= RSP_RANGE;
            end else if (request_word_index_i != source_loaded_words[5:0]) begin
              completion_code <= RSP_SEQUENCE;
              protocol_error_sticky <= 1'b1;
            end else begin
              source_loaded_words <= source_loaded_words + 1'b1;
              completion_code <= RSP_OK;
            end
            completion_pending <= 1'b1;
          end

          OP_QUIESCE: begin
            if (source_loaded_words != 7'd64 || finite_select_o || armed) begin
              completion_code <= RSP_PRECONDITION;
              completion_pending <= 1'b1;
            end else if (vendor_quiesce_safe) begin
              finite_select_o <= 1'b1;
              completion_code <= RSP_OK;
              completion_pending <= 1'b1;
            end else begin
              quiesce_wait <= 1'b1;
            end
          end

          OP_ARM_FOLLOW,
          OP_ARM_INIT: begin
            if (!finite_select_o || source_loaded_words != 7'd64 || armed ||
                tx_state != TX_IDLE || rx_state_tx != RX_IDLE ||
                arm_send_tx || arm_ack_tx) begin
              completion_code <= RSP_PRECONDITION;
              completion_pending <= 1'b1;
            end else begin
              capture_words_tx <= 7'd0;
              tx_accepted_cycles <= 7'd0;
              rx_accepted_cycles_tx <= 7'd0;
              tx_drive_enable <= 1'b0;
              tx_ready_loss_sticky <= 1'b0;
              protocol_error_sticky <= 1'b0;
              fcs_error_sticky_tx <= 1'b0;
              fec_corrected_sticky_tx <= 1'b0;
              fec_uncorrectable_sticky_tx <= 1'b0;
              rx_rejected_sticky_tx <= 1'b0;
              rx_reject_reason_tx <= 2'b0;
              rx_reject_ena_tx <= 4'b0;
              rx_reject_sop_tx <= 4'b0;
              rx_reject_eop_tx <= 4'b0;
              rx_reject_mty_tx <= 16'b0;
              rx_reject_err_tx <= 4'b0;
              rx_reject_offset_tx <= 2'b0;
              arm_bundle_tx <= {request_opcode_i == OP_ARM_FOLLOW,
                                request_tag_i};
              arm_send_tx <= 1'b1;
              arm_wait_tx <= 1'b1;
            end
          end

          OP_START: begin
            if (!finite_select_o || !armed || follower ||
                tx_state != TX_IDLE || rx_state_tx != RX_WAIT_SOP) begin
              completion_code <= RSP_PRECONDITION;
            end else begin
              tx_word_index <= 6'd0;
              tx_drive_enable <= cmac_tx_rdy_i;
              tx_state <= TX_SEND;
              completion_code <= RSP_OK;
            end
            completion_pending <= 1'b1;
          end

          OP_READ: begin
            if (!rx_committed || !tx_done) begin
              completion_code <= RSP_PRECONDITION;
              completion_pending <= 1'b1;
            end else begin
              capture_read_addr <= request_word_index_i;
              read_wait <= 2'd1;
            end
          end

          OP_STATUS: begin
            completion_code <= RSP_OK;
            completion_pending <= 1'b1;
          end

          OP_ABORT: begin
            tx_state <= TX_ABORTED;
            tx_drive_enable <= 1'b0;
            rx_state_tx <= RX_REJECTED;
            armed <= 1'b0;
            rx_rejected_sticky_tx <= 1'b1;
            completion_code <= RSP_OK;
            completion_pending <= 1'b1;
          end

          default: begin
            completion_code <= RSP_BAD_OPCODE;
            protocol_error_sticky <= 1'b1;
            completion_pending <= 1'b1;
          end
        endcase
      end

      if (tx_state == TX_SEND) begin
        // Match the generated CMAC example's registered HALT behavior without
        // creating a combinational tx_rdyout-to-LBUS-valid path.  The cycle in
        // which ready falls is still a real transfer and advances once; one
        // registered cycle later all ENA/SOP/EOP controls are zero.  After
        // ready rises, transmission resumes with the next unsent word.
        tx_drive_enable <= cmac_tx_rdy_i;
        if (!cmac_tx_rdy_i) begin
          tx_ready_loss_sticky <= 1'b1;
        end
        if (finite_tx_cycle_accept) begin
          tx_accepted_cycles <= tx_accepted_cycles + 1'b1;
          if (tx_word_index == 6'd63) begin
            tx_state <= TX_DONE;
            tx_drive_enable <= 1'b0;
          end else begin
            tx_word_index <= tx_word_index + 1'b1;
          end
        end
      end
    end
  end

  // RX LBUS is sampled only in RXUSRCLK2. The result bundle is held stable
  // until its XPM acknowledge returns; capture RAM stays immutable afterward.
  always_ff @(posedge rxusrclk2_i) begin
    if (rx_reset_i) begin
      rx_state_rx <= RX_IDLE;
      capture_words_rx <= 7'd0;
      rx_sop_offset_rx <= 2'd0;
      rx_previous_cycle_data_rx <= 512'b0;
      capture_write_valid_rx <= 1'b0;
      capture_write_addr_rx <= 6'd0;
      capture_write_data_rx <= 512'b0;
      rx_follower_rx <= 1'b0;
      rx_rejected_sticky_rx <= 1'b0;
      fcs_error_sticky_rx <= 1'b0;
      fec_corrected_sticky_rx <= 1'b0;
      fec_uncorrectable_sticky_rx <= 1'b0;
      rx_start_toggle_rx <= 1'b0;
      rx_result_send_rx <= 1'b0;
      rx_result_bundle_rx <= 47'b0;
    end else begin
      // The pipeline drives capture RAM on the following edge.  Valid is
      // asserted anew only for a structurally accepted aligned word.
      capture_write_valid_rx <= 1'b0;
      if (rx_result_send_rx && rx_result_ack_rx)
        rx_result_send_rx <= 1'b0;

      if (arm_valid_rx) begin
        rx_state_rx <= RX_WAIT_SOP;
        capture_words_rx <= 7'd0;
        rx_sop_offset_rx <= 2'd0;
        rx_previous_cycle_data_rx <= 512'b0;
        capture_write_valid_rx <= 1'b0;
        capture_write_addr_rx <= 6'd0;
        capture_write_data_rx <= 512'b0;
        rx_follower_rx <= arm_bundle_rx[16];
        rx_rejected_sticky_rx <= 1'b0;
        fcs_error_sticky_rx <= 1'b0;
        fec_corrected_sticky_rx <= 1'b0;
        fec_uncorrectable_sticky_rx <= 1'b0;
      end else begin
        // Packet-level pulses become owned only after finite SOP.  The EOP
        // segment's aligned rx_errout remains the current-frame oracle.
        if (rx_state_rx == RX_ACTIVE || rx_state_rx == RX_COMMIT) begin
          if (rx_fcs_error_i)
            fcs_error_sticky_rx <= 1'b1;
          if (rx_fec_corrected_i)
            fec_corrected_sticky_rx <= 1'b1;
          if (rx_fec_uncorrectable_i)
            fec_uncorrectable_sticky_rx <= 1'b1;
        end

        case (rx_state_rx)
          RX_WAIT_SOP: begin
            // An old packet may end in an earlier segment of this same cycle.
            // Ignore everything until exactly one enabled SOP is observed.
            if (rx_detected_sop_onehot) begin
              if (li7_rx_start_cycle_valid(
                    rx_detected_sop_offset, rx_ena_i, rx_sop_i, rx_eop_i)) begin
                rx_state_rx <= RX_ACTIVE;
                rx_sop_offset_rx <= rx_detected_sop_offset;
                rx_previous_cycle_data_rx <= rx_data_i;
                if (rx_follower_rx)
                  rx_start_toggle_rx <= ~rx_start_toggle_rx;

                // Offset zero already contains a complete first 512-bit word.
                // Nonzero offsets complete word zero on the following cycle.
                if (rx_detected_sop_offset == 2'd0) begin
                  capture_write_valid_rx <= 1'b1;
                  capture_write_addr_rx <= 6'd0;
                  capture_write_data_rx <= rx_data_i;
                  capture_words_rx <= 7'd1;
                end
              end else begin
                rx_state_rx <= RX_REJECTED;
                rx_rejected_sticky_rx <= 1'b1;
                if (|(rx_ena_i & rx_eop_i & rx_err_i))
                  fcs_error_sticky_rx <= 1'b1;
                rx_result_bundle_rx <= {
                  rx_detected_sop_offset,
                  rx_err_i, rx_mty_i, rx_eop_i, rx_sop_i, rx_ena_i, 2'd1,
                  rx_fec_corrected_i,
                  rx_fec_uncorrectable_i,
                  rx_fcs_error_i | (|(rx_ena_i & rx_eop_i & rx_err_i)),
                  1'b1, 7'd0};
                rx_result_send_rx <= 1'b1;
              end
            end
          end

          RX_ACTIVE: begin
            // A registered CMAC TX HALT can create whole idle LBUS cycles
            // while retaining ownership of this finite frame.  Do not shift
            // the alignment history or advance the capture pipeline on those
            // cycles.  Partial enables, a second SOP, or an early EOP remain
            // structural failures.
            if (rx_ena_i == 4'b0000) begin
              // PG203 defines rx_enaout as the qualifier for every other RX
              // LBUS output.  During a whole-cycle gap SOP/EOP/MTY/ERR are
              // invalid and may retain arbitrary values; preserve the prior
              // accepted raw cycle using ENA alone.
            end else begin
              // Register both the raw cycle and the fixed-offset aligned
              // word. BRAM consumes this pipeline one edge later; control
              // validation never sits on the 512-bit CMAC-to-RAM data path.
              rx_previous_cycle_data_rx <= rx_data_i;
              capture_write_addr_rx <= capture_words_rx[5:0];
              capture_write_data_rx <= rx_aligned_word;

              if (capture_words_rx == 7'd63) begin
                if (li7_rx_final_cycle_valid(
                      rx_sop_offset_rx, rx_ena_i, rx_sop_i, rx_eop_i,
                      rx_mty_i, rx_err_i)) begin
                  capture_write_valid_rx <= 1'b1;
                  capture_words_rx <= 7'd64;
                  rx_state_rx <= RX_COMMIT;
                end else begin
                  rx_state_rx <= RX_REJECTED;
                  rx_rejected_sticky_rx <= 1'b1;
                  if (|(rx_ena_i & rx_eop_i & rx_err_i))
                    fcs_error_sticky_rx <= 1'b1;
                  rx_result_bundle_rx <= {
                    rx_sop_offset_rx,
                    rx_err_i, rx_mty_i, rx_eop_i, rx_sop_i, rx_ena_i, 2'd3,
                    fec_corrected_sticky_rx | rx_fec_corrected_i,
                    fec_uncorrectable_sticky_rx | rx_fec_uncorrectable_i,
                    fcs_error_sticky_rx | rx_fcs_error_i |
                      (|(rx_ena_i & rx_eop_i & rx_err_i)),
                    1'b1, capture_words_rx};
                  rx_result_send_rx <= 1'b1;
                end
              end else if (rx_ena_i == 4'b1111 &&
                           rx_sop_i == 4'b0000 &&
                           rx_eop_i == 4'b0000) begin
                // rx_mtyout/rx_errout are invalid away from EOP by PG203.
                capture_write_valid_rx <= 1'b1;
                capture_words_rx <= capture_words_rx + 1'b1;
              end else begin
                rx_state_rx <= RX_REJECTED;
                rx_rejected_sticky_rx <= 1'b1;
                if (|(rx_ena_i & rx_eop_i & rx_err_i))
                  fcs_error_sticky_rx <= 1'b1;
                rx_result_bundle_rx <= {
                  rx_sop_offset_rx,
                  rx_err_i, rx_mty_i, rx_eop_i, rx_sop_i, rx_ena_i, 2'd2,
                  fec_corrected_sticky_rx | rx_fec_corrected_i,
                  fec_uncorrectable_sticky_rx | rx_fec_uncorrectable_i,
                  fcs_error_sticky_rx | rx_fcs_error_i |
                    (|(rx_ena_i & rx_eop_i & rx_err_i)),
                  1'b1, capture_words_rx};
                rx_result_send_rx <= 1'b1;
              end
            end
          end

          RX_COMMIT: begin
            // The final pipelined word is written by capture RAM on this edge.
            // The result then crosses four synchronized TXUSRCLK2 stages, so
            // host reads cannot overtake the physical RAM commit.
            rx_state_rx <= RX_DONE;
            rx_result_bundle_rx <= {
              36'b0,
              fec_corrected_sticky_rx | rx_fec_corrected_i,
              fec_uncorrectable_sticky_rx | rx_fec_uncorrectable_i,
              fcs_error_sticky_rx | rx_fcs_error_i,
              1'b0, 7'd64};
            rx_result_send_rx <= 1'b1;
          end

          default: begin
            // IDLE, DONE, and REJECTED intentionally ignore later traffic.
          end
        endcase
      end
    end
  end
endmodule

`default_nettype wire
