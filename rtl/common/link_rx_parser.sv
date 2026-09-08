`timescale 1ns/1ps

// Compact frame parser with a private 256-byte payload buffer. Payload is not
// exposed until direction, length, sequence, and CRC all pass.
module link_rx_parser (
  input  wire        clk_i,
  input  wire        resetn_i,
  input  wire        arm_i,
  input  wire [1:0]  expected_direction_i,
  input  wire [15:0] first_sequence_i,
  input  wire [1:0]  lane_i,
  output logic [7:0] data_o,
  output logic       data_valid_o,
  input  wire        data_ready_i,
  input  wire [9:0]  commit_space_i,
  output logic       frame_done_o,
  output logic       crc_error_o,
  output logic       sequence_error_o,
  output logic       overflow_o,
  output logic [15:0] last_sequence_o
);
  typedef enum logic [3:0] {
    ST_SEARCH, ST_CONTROL, ST_SEQ0, ST_SEQ1, ST_LEN0, ST_LEN1,
    ST_PAYLOAD, ST_CRC0, ST_CRC1, ST_CRC2, ST_CRC3
  } state_t;

  state_t state;
  logic [1:0] pair_index;
  logic [7:0] assembled_byte;
  logic [1:0] sync_index;
  logic [31:0] sync_shift;
  logic [15:0] received_sequence;
  logic [15:0] expected_sequence;
  logic [8:0] payload_length;
  logic [8:0] payload_index;
  logic [31:0] crc_state;
  logic [31:0] received_crc;
  logic header_valid;
  logic frame_storage_conflict;

  (* ram_style = "distributed" *) logic [7:0] frame_buffer [0:255];
  logic drain_active;
  logic [8:0] drain_index;
  logic [8:0] drain_length;

  function automatic [31:0] crc_byte(input [31:0] crc, input [7:0] value);
    reg [31:0] next_crc;
    begin
      next_crc = crc;
      for (int bit_index = 0; bit_index < 8; bit_index++) begin
        if (next_crc[0] ^ value[bit_index])
          next_crc = (next_crc >> 1) ^ 32'h82F63B78;
        else
          next_crc = next_crc >> 1;
      end
      crc_byte = next_crc;
    end
  endfunction

  wire [7:0] completed_byte = {
    lane_i[1], lane_i[0], assembled_byte[5:0]
  };
  wire completed_byte_valid = (pair_index == 2'd3);
  wire [31:0] sync_shift_next = {lane_i[1], lane_i[0], sync_shift[31:2]};

  always_comb begin
    data_valid_o = drain_active;
    data_o = frame_buffer[drain_index[7:0]];
  end

  // The payload RAM has no reset port. Transaction state and drain_valid
  // make pre-reset contents unreachable, while keeping the inferred LUTRAM
  // write port free of an asynchronous reset.
  always_ff @(posedge clk_i) begin
    if (resetn_i && arm_i && (state == ST_PAYLOAD) &&
        completed_byte_valid &&
        !(drain_active && (payload_index >= drain_index))) begin
      frame_buffer[payload_index[7:0]] <= completed_byte;
    end
  end

  always_ff @(posedge clk_i or negedge resetn_i) begin
    if (!resetn_i) begin
      state <= ST_SEARCH;
      pair_index <= 2'd0;
      assembled_byte <= 8'd0;
      sync_index <= 2'd0;
      sync_shift <= 32'd0;
      received_sequence <= 16'd0;
      expected_sequence <= 16'd0;
      payload_length <= 9'd0;
      payload_index <= 9'd0;
      crc_state <= 32'hFFFFFFFF;
      received_crc <= 32'd0;
      header_valid <= 1'b0;
      frame_storage_conflict <= 1'b0;
      frame_done_o <= 1'b0;
      crc_error_o <= 1'b0;
      sequence_error_o <= 1'b0;
      overflow_o <= 1'b0;
      last_sequence_o <= 16'hFFFF;
      drain_active <= 1'b0;
      drain_index <= 9'd0;
      drain_length <= 9'd0;
    end else begin
      frame_done_o <= 1'b0;
      crc_error_o <= 1'b0;
      sequence_error_o <= 1'b0;
      overflow_o <= 1'b0;

      if (drain_active && data_ready_i) begin
        if (drain_index + 1'b1 >= drain_length) begin
          drain_active <= 1'b0;
          drain_index <= 9'd0;
        end else begin
          drain_index <= drain_index + 1'b1;
        end
      end

      if (!arm_i) begin
        state <= ST_SEARCH;
        pair_index <= 2'd0;
        sync_index <= 2'd0;
        sync_shift <= 32'd0;
        expected_sequence <= first_sequence_i;
        header_valid <= 1'b0;
        frame_storage_conflict <= 1'b0;
      end else if (state == ST_SEARCH) begin
        // Search at the native two-bit link cadence, not at an assumed byte
        // phase. This makes initial clock-only cycles and back-to-back frames
        // harmless while preserving lane0-before-lane1 ordering.
        sync_shift <= sync_shift_next;
        pair_index <= 2'd0;
        assembled_byte <= 8'd0;
        if (sync_shift_next == 32'h3CC35AA5) begin
          state <= ST_CONTROL;
          crc_state <= 32'hFFFFFFFF;
          header_valid <= 1'b1;
          frame_storage_conflict <= 1'b0;
        end
      end else begin
        assembled_byte[pair_index*2 +: 2] <= lane_i;
        if (pair_index != 2'd3) begin
          pair_index <= pair_index + 1'b1;
        end else begin
          pair_index <= 2'd0;
          case (state)
            ST_CONTROL: begin
              header_valid <= (completed_byte[7:4] == 4'h1) &&
                              (completed_byte[3:2] == expected_direction_i) &&
                              (completed_byte[1:0] == 2'b00);
              crc_state <= crc_byte(crc_state, completed_byte);
              state <= ST_SEQ0;
            end
            ST_SEQ0: begin
              received_sequence[7:0] <= completed_byte;
              crc_state <= crc_byte(crc_state, completed_byte);
              state <= ST_SEQ1;
            end
            ST_SEQ1: begin
              received_sequence[15:8] <= completed_byte;
              crc_state <= crc_byte(crc_state, completed_byte);
              state <= ST_LEN0;
            end
            ST_LEN0: begin
              payload_length[7:0] <= completed_byte;
              crc_state <= crc_byte(crc_state, completed_byte);
              state <= ST_LEN1;
            end
            ST_LEN1: begin
              payload_length[8] <= completed_byte[0];
              crc_state <= crc_byte(crc_state, completed_byte);
              payload_index <= 9'd0;
              if (header_valid && (completed_byte[7:1] == 7'd0) &&
                  ({completed_byte[0], payload_length[7:0]} >= 9'd1) &&
                  ({completed_byte[0], payload_length[7:0]} <= 9'd256)) begin
                state <= ST_PAYLOAD;
              end else begin
                header_valid <= 1'b0;
                state <= ST_SEARCH;
              end
            end
            ST_PAYLOAD: begin
              // The previous committed frame drains four times faster than a
              // new payload arrives. A stalled drain makes the new frame fail
              // closed instead of overwriting an unread byte.
              if (drain_active && (payload_index >= drain_index)) begin
                frame_storage_conflict <= 1'b1;
              end
              crc_state <= crc_byte(crc_state, completed_byte);
              if (payload_index + 1'b1 >= payload_length) begin
                state <= ST_CRC0;
              end else begin
                payload_index <= payload_index + 1'b1;
              end
            end
            ST_CRC0: begin received_crc[7:0] <= completed_byte; state <= ST_CRC1; end
            ST_CRC1: begin received_crc[15:8] <= completed_byte; state <= ST_CRC2; end
            ST_CRC2: begin received_crc[23:16] <= completed_byte; state <= ST_CRC3; end
            ST_CRC3: begin
              received_crc[31:24] <= completed_byte;
              if (!header_valid) begin
                state <= ST_SEARCH;
              end else if ({completed_byte, received_crc[23:0]} != ~crc_state) begin
                crc_error_o <= 1'b1;
                state <= ST_SEARCH;
              end else if (received_sequence != expected_sequence) begin
                sequence_error_o <= 1'b1;
                state <= ST_SEARCH;
              end else if (frame_storage_conflict || drain_active ||
                           (commit_space_i < payload_length)) begin
                overflow_o <= 1'b1;
                state <= ST_SEARCH;
              end else begin
                drain_active <= 1'b1;
                drain_index <= 9'd0;
                drain_length <= payload_length;
                frame_done_o <= 1'b1;
                last_sequence_o <= received_sequence;
                expected_sequence <= expected_sequence + 1'b1;
                state <= ST_SEARCH;
              end
            end
            default: state <= ST_SEARCH;
          endcase
        end
      end
    end
  end
endmodule
