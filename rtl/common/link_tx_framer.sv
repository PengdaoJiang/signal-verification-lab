`timescale 1ns/1ps

// Back-to-back compact DATA framer. One lane pair is emitted every link clock;
// lane 0 is the earlier serialized bit and every byte is LSB first.
module link_tx_framer (
  input  wire        clk_i,
  input  wire        resetn_i,
  input  wire        arm_i,
  input  wire [1:0]  direction_i,
  input  wire [15:0] first_sequence_i,
  input  wire [8:0]  payload_length_i,
  input  wire [15:0] frame_limit_i,
  input  wire [7:0]  data_i,
  input  wire        data_valid_i,
  output logic       data_ready_o,
  output logic [1:0] lane_o,
  output logic       active_o,
  output logic       frame_done_o,
  output logic       transaction_done_o,
  output logic       underflow_o
);
  typedef enum logic [3:0] {
    ST_IDLE, ST_SYNC, ST_CONTROL, ST_SEQ0, ST_SEQ1,
    ST_LEN0, ST_LEN1, ST_PAYLOAD, ST_CRC0, ST_CRC1, ST_CRC2, ST_CRC3
  } state_t;

  state_t state;
  logic [1:0] pair_index;
  logic [1:0] sync_index;
  logic [7:0] current_byte;
  logic [8:0] payload_index;
  logic [8:0] payload_length;
  logic [1:0] direction_value;
  logic [15:0] frame_limit_value;
  logic [15:0] sequence_value;
  logic [15:0] frames_sent;
  logic [31:0] crc_state;
  logic [31:0] crc_final;
  logic armed_session;

  function automatic [7:0] sync_byte(input [1:0] index);
    case (index)
      2'd0: sync_byte = 8'hA5;
      2'd1: sync_byte = 8'h5A;
      2'd2: sync_byte = 8'hC3;
      default: sync_byte = 8'h3C;
    endcase
  endfunction

  function automatic [31:0] crc_pair(input [31:0] crc, input [1:0] bits);
    reg [31:0] next_crc;
    begin
      next_crc = crc;
      for (int lane = 0; lane < 2; lane++) begin
        if (next_crc[0] ^ bits[lane])
          next_crc = (next_crc >> 1) ^ 32'h82F63B78;
        else
          next_crc = next_crc >> 1;
      end
      crc_pair = next_crc;
    end
  endfunction

  wire crc_covered = state inside {ST_CONTROL, ST_SEQ0, ST_SEQ1, ST_LEN0, ST_LEN1, ST_PAYLOAD};
  wire [31:0] crc_after_pair = crc_pair(crc_state, lane_o);
  wire [7:0] control_byte = {4'h1, direction_value, 2'b00};
  wire final_frame = (frame_limit_value != 16'd0) && ((frames_sent + 1'b1) >= frame_limit_value);

  always_comb begin
    lane_o = current_byte[pair_index*2 +: 2];
    data_ready_o = active_o && (pair_index == 2'd3) &&
                   (((state == ST_LEN1) && data_valid_i) ||
                    ((state == ST_PAYLOAD) &&
                     (payload_index + 1'b1 < payload_length) && data_valid_i));
  end

  always_ff @(posedge clk_i or negedge resetn_i) begin
    if (!resetn_i) begin
      state <= ST_IDLE;
      pair_index <= 2'd0;
      sync_index <= 2'd0;
      current_byte <= 8'h00;
      payload_index <= 9'd0;
      payload_length <= 9'd256;
      direction_value <= 2'd0;
      frame_limit_value <= 16'd0;
      sequence_value <= 16'd0;
      frames_sent <= 16'd0;
      crc_state <= 32'hFFFFFFFF;
      crc_final <= 32'd0;
      active_o <= 1'b0;
      frame_done_o <= 1'b0;
      transaction_done_o <= 1'b0;
      underflow_o <= 1'b0;
      armed_session <= 1'b0;
    end else begin
      frame_done_o <= 1'b0;
      transaction_done_o <= 1'b0;
      underflow_o <= 1'b0;

      if (!arm_i)
        armed_session <= 1'b0;

      if (!active_o) begin
        pair_index <= 2'd0;
        current_byte <= 8'h00;
        if (arm_i && !armed_session &&
            (payload_length_i >= 9'd1) && (payload_length_i <= 9'd256)) begin
          armed_session <= 1'b1;
          active_o <= 1'b1;
          state <= ST_SYNC;
          sync_index <= 2'd0;
          current_byte <= 8'hA5;
          payload_length <= payload_length_i;
          direction_value <= direction_i;
          frame_limit_value <= frame_limit_i;
          sequence_value <= first_sequence_i;
          frames_sent <= 16'd0;
          crc_state <= 32'hFFFFFFFF;
        end
      end else begin
        if (crc_covered)
          crc_state <= crc_after_pair;

        if (pair_index != 2'd3) begin
          pair_index <= pair_index + 1'b1;
        end else begin
          pair_index <= 2'd0;
          case (state)
            ST_SYNC: begin
              if (sync_index == 2'd3) begin
                state <= ST_CONTROL;
                current_byte <= control_byte;
                crc_state <= 32'hFFFFFFFF;
              end else begin
                sync_index <= sync_index + 1'b1;
                current_byte <= sync_byte(sync_index + 1'b1);
              end
            end
            ST_CONTROL: begin state <= ST_SEQ0; current_byte <= sequence_value[7:0]; end
            ST_SEQ0: begin state <= ST_SEQ1; current_byte <= sequence_value[15:8]; end
            ST_SEQ1: begin state <= ST_LEN0; current_byte <= payload_length[7:0]; end
            ST_LEN0: begin state <= ST_LEN1; current_byte <= {7'd0, payload_length[8]}; end
            ST_LEN1: begin
              state <= ST_PAYLOAD;
              payload_index <= 9'd0;
              if (data_valid_i)
                current_byte <= data_i;
              else begin
                current_byte <= 8'h00;
                underflow_o <= 1'b1;
                active_o <= 1'b0;
                state <= ST_IDLE;
              end
            end
            ST_PAYLOAD: begin
              if (payload_index + 1'b1 < payload_length) begin
                payload_index <= payload_index + 1'b1;
                if (data_valid_i)
                  current_byte <= data_i;
                else begin
                  current_byte <= 8'h00;
                  underflow_o <= 1'b1;
                  active_o <= 1'b0;
                  state <= ST_IDLE;
                end
              end else begin
                state <= ST_CRC0;
                crc_final <= ~crc_after_pair;
                current_byte <= ~crc_after_pair[7:0];
              end
            end
            ST_CRC0: begin state <= ST_CRC1; current_byte <= crc_final[15:8]; end
            ST_CRC1: begin state <= ST_CRC2; current_byte <= crc_final[23:16]; end
            ST_CRC2: begin state <= ST_CRC3; current_byte <= crc_final[31:24]; end
            ST_CRC3: begin
              frame_done_o <= 1'b1;
              frames_sent <= frames_sent + 1'b1;
              sequence_value <= sequence_value + 1'b1;
              if (final_frame || !arm_i) begin
                active_o <= 1'b0;
                transaction_done_o <= 1'b1;
                state <= ST_IDLE;
                current_byte <= 8'h00;
              end else begin
                state <= ST_SYNC;
                sync_index <= 2'd0;
                current_byte <= 8'hA5;
                crc_state <= 32'hFFFFFFFF;
              end
            end
            default: begin
              active_o <= 1'b0;
              state <= ST_IDLE;
              current_byte <= 8'h00;
            end
          endcase
        end
      end
    end
  end
endmodule
