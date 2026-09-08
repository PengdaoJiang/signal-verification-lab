`timescale 1ns/1ps

// Asynchronous assertion, four destination-clock-edge synchronous release.
module link_reset_sync (
  input  logic clk_i,
  input  logic async_resetn_i,
  output logic resetn_o
);
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [3:0] release_pipe;

  always_ff @(posedge clk_i or negedge async_resetn_i) begin
    if (!async_resetn_i)
      release_pipe <= 4'b0000;
    else
      release_pipe <= {release_pipe[2:0], 1'b1};
  end

  assign resetn_o = release_pipe[3];
endmodule
