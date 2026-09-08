`timescale 1ns/1ps
`default_nettype none

// Atomic VIO-to-TXUSRCLK2 request/response bridge around the finite engine.
// The VIO output bundle is sampled only after its request toggle changes and
// remains held until the matching atomic response returns.
module finite_stream_bridge (
  input  wire         mgmt_clk_i,
  input  wire         mgmt_reset_i,
  input  wire [31:0]  vio_request_i,
  input  wire [511:0] vio_source_data_i,
  output logic [127:0] vio_status_o,
  output logic [511:0] vio_capture_data_o,

  input  wire         txusrclk2_i,
  input  wire         tx_reset_i,
  input  wire         rxusrclk2_i,
  input  wire         rx_reset_i,
  input  wire [3:0]   vendor_tx_ena_i,
  input  wire [3:0]   vendor_tx_eop_i,
  input  wire         cmac_tx_rdy_i,
  output wire         finite_select_o,
  output wire [511:0] finite_tx_data_o,
  output wire [3:0]   finite_tx_ena_o,
  output wire [3:0]   finite_tx_sop_o,
  output wire [3:0]   finite_tx_eop_o,
  output wire [15:0]  finite_tx_mty_o,
  output wire [3:0]   finite_tx_err_o,

  input  wire [511:0] rx_data_i,
  input  wire [3:0]   rx_ena_i,
  input  wire [3:0]   rx_sop_i,
  input  wire [3:0]   rx_eop_i,
  input  wire [15:0]  rx_mty_i,
  input  wire [3:0]   rx_err_i,
  input  wire         rx_fcs_error_i,
  input  wire         rx_fec_corrected_i,
  input  wire         rx_fec_uncorrectable_i
);
  localparam integer REQUEST_WIDTH = 539;
  localparam integer RESPONSE_WIDTH = 651;

  typedef enum logic [2:0] {
    MGMT_WARMUP,
    MGMT_IDLE,
    MGMT_SEND,
    MGMT_WAIT_RESPONSE,
    MGMT_DRAIN
  } mgmt_state_t;

  mgmt_state_t mgmt_state;
  logic [2:0] warmup_count;
  logic request_toggle_seen;
  logic request_send;
  wire request_received;
  logic [REQUEST_WIDTH-1:0] request_bundle_hold;
  wire [REQUEST_WIDTH-1:0] request_bundle_tx;
  wire request_valid_tx;

  wire response_valid_tx;
  wire response_ready_tx;
  wire response_toggle_tx;
  wire [3:0] response_code_tx;
  wire [5:0] response_word_index_tx;
  wire [511:0] response_data_tx;
  wire [127:0] response_status_tx;
  wire [127:0] live_status_tx;
  wire [RESPONSE_WIDTH-1:0] response_bundle_tx = {
    response_status_tx,
    response_data_tx,
    response_word_index_tx,
    response_code_tx,
    response_toggle_tx
  };
  wire [RESPONSE_WIDTH-1:0] response_bundle_mgmt;
  wire response_valid_mgmt;

  xpm_cdc_handshake #(
    .DEST_EXT_HSK(0), .DEST_SYNC_FF(4), .INIT_SYNC_FF(1),
    .SIM_ASSERT_CHK(1), .SRC_SYNC_FF(4), .WIDTH(REQUEST_WIDTH)
  ) request_to_tx_i (
    .src_clk(mgmt_clk_i), .src_in(request_bundle_hold),
    .src_send(request_send), .src_rcv(request_received),
    .dest_clk(txusrclk2_i), .dest_out(request_bundle_tx),
    .dest_req(request_valid_tx), .dest_ack(1'b0)
  );

  xpm_cdc_handshake #(
    .DEST_EXT_HSK(0), .DEST_SYNC_FF(4), .INIT_SYNC_FF(1),
    .SIM_ASSERT_CHK(1), .SRC_SYNC_FF(4), .WIDTH(RESPONSE_WIDTH)
  ) response_to_mgmt_i (
    .src_clk(txusrclk2_i), .src_in(response_bundle_tx),
    .src_send(response_valid_tx), .src_rcv(response_ready_tx),
    .dest_clk(mgmt_clk_i), .dest_out(response_bundle_mgmt),
    .dest_req(response_valid_mgmt), .dest_ack(1'b0)
  );

  wire request_toggle_tx = request_bundle_tx[0];
  wire [3:0] request_opcode_tx = request_bundle_tx[4:1];
  wire [5:0] request_word_index_tx = request_bundle_tx[10:5];
  wire [15:0] request_tag_tx = request_bundle_tx[26:11];
  wire [511:0] request_data_tx = request_bundle_tx[538:27];

  finite_stream_engine engine_i (
    .txusrclk2_i(txusrclk2_i), .tx_reset_i(tx_reset_i),
    .rxusrclk2_i(rxusrclk2_i), .rx_reset_i(rx_reset_i),
    .request_valid_i(request_valid_tx), .request_ready_o(),
    .request_toggle_i(request_toggle_tx),
    .request_opcode_i(request_opcode_tx),
    .request_word_index_i(request_word_index_tx),
    .request_tag_i(request_tag_tx), .request_data_i(request_data_tx),
    .response_valid_o(response_valid_tx),
    .response_ready_i(response_ready_tx),
    .response_toggle_o(response_toggle_tx),
    .response_code_o(response_code_tx),
    .response_word_index_o(response_word_index_tx),
    .response_data_o(response_data_tx),
    .response_status_o(response_status_tx),
    .vendor_tx_ena_i(vendor_tx_ena_i),
    .vendor_tx_eop_i(vendor_tx_eop_i),
    .cmac_tx_rdy_i(cmac_tx_rdy_i),
    .finite_select_o(finite_select_o),
    .finite_tx_data_o(finite_tx_data_o),
    .finite_tx_ena_o(finite_tx_ena_o),
    .finite_tx_sop_o(finite_tx_sop_o),
    .finite_tx_eop_o(finite_tx_eop_o),
    .finite_tx_mty_o(finite_tx_mty_o),
    .finite_tx_err_o(finite_tx_err_o),
    .rx_data_i(rx_data_i), .rx_ena_i(rx_ena_i),
    .rx_sop_i(rx_sop_i), .rx_eop_i(rx_eop_i),
    .rx_mty_i(rx_mty_i), .rx_err_i(rx_err_i),
    .rx_fcs_error_i(rx_fcs_error_i),
    .rx_fec_corrected_i(rx_fec_corrected_i),
    .rx_fec_uncorrectable_i(rx_fec_uncorrectable_i),
    .live_status_o(live_status_tx)
  );

  always_ff @(posedge mgmt_clk_i or posedge mgmt_reset_i) begin
    if (mgmt_reset_i) begin
      mgmt_state <= MGMT_WARMUP;
      warmup_count <= 3'd0;
      request_toggle_seen <= 1'b0;
      request_send <= 1'b0;
      request_bundle_hold <= {REQUEST_WIDTH{1'b0}};
      vio_status_o <= 128'b0;
      vio_capture_data_o <= 512'b0;
    end else begin
      case (mgmt_state)
        MGMT_WARMUP: begin
          request_toggle_seen <= vio_request_i[0];
          vio_status_o[0] <= vio_request_i[0];
          if (warmup_count == 3'd4)
            mgmt_state <= MGMT_IDLE;
          else
            warmup_count <= warmup_count + 1'b1;
        end

        MGMT_IDLE: begin
          if (vio_request_i[31:27] != 5'b00000) begin
            // Reserved request bits are never forwarded.  Reflect a local
            // BAD_OPCODE-style response on the matching toggle.
            if (vio_request_i[0] != request_toggle_seen) begin
              request_toggle_seen <= vio_request_i[0];
              vio_status_o <= 128'b0;
              vio_status_o[0] <= vio_request_i[0];
              vio_status_o[121:118] <= 4'd1;
            end
          end else if (vio_request_i[0] != request_toggle_seen) begin
            request_bundle_hold <= {vio_source_data_i,
                                    vio_request_i[26:0]};
            request_toggle_seen <= vio_request_i[0];
            request_send <= 1'b1;
            mgmt_state <= MGMT_SEND;
          end
        end

        MGMT_SEND: begin
          if (request_received) begin
            request_send <= 1'b0;
            mgmt_state <= MGMT_WAIT_RESPONSE;
          end
        end

        MGMT_WAIT_RESPONSE: begin
          if (response_valid_mgmt) begin
            if (response_bundle_mgmt[0] != request_toggle_seen) begin
              vio_status_o <= 128'b0;
              vio_status_o[0] <= request_toggle_seen;
              vio_status_o[121:118] <= 4'd5;
            end else begin
              vio_status_o <= response_bundle_mgmt[650:523];
              vio_status_o[0] <= response_bundle_mgmt[0];
              vio_status_o[121:118] <= response_bundle_mgmt[4:1];
              vio_status_o[127:122] <= response_bundle_mgmt[10:5];
              vio_capture_data_o <= response_bundle_mgmt[522:11];
            end
            mgmt_state <= MGMT_DRAIN;
          end
        end

        default: begin
          if (!request_received)
            mgmt_state <= MGMT_IDLE;
        end
      endcase
    end
  end
endmodule

`default_nettype wire
