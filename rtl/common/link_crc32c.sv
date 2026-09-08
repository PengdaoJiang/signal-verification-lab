`timescale 1ns/1ps

// Reflected CRC-32C update for one two-lane SDR transfer.  data_i[0]
// (lane 0) is consumed before data_i[1] (lane 1).
module link_crc32c (
  input  logic        clk_i,
  input  logic        resetn_i,
  input  logic        clear_i,
  input  logic        valid_i,
  input  logic [1:0]  data_i,
  output logic [31:0] state_o,
  output logic [31:0] final_crc_o
);
  localparam logic [31:0] POLY = 32'h82F63B78;

  function automatic logic [31:0] update_bit(
    input logic [31:0] crc,
    input logic        bit_value
  );
    logic feedback;
    begin
      feedback = crc[0] ^ bit_value;
      update_bit = (crc >> 1) ^ (feedback ? POLY : 32'h00000000);
    end
  endfunction

  always_ff @(posedge clk_i or negedge resetn_i) begin
    if (!resetn_i)
      state_o <= 32'hFFFFFFFF;
    else if (clear_i)
      state_o <= 32'hFFFFFFFF;
    else if (valid_i)
      state_o <= update_bit(update_bit(state_o, data_i[0]), data_i[1]);
  end

  always_comb final_crc_o = state_o ^ 32'hFFFFFFFF;
endmodule
