`timescale 1ns/1ps

module tb_link_crc32c;
  logic clk = 1'b0;
  logic resetn = 1'b0;
  logic clear = 1'b0;
  logic valid = 1'b0;
  logic [1:0] data = 2'b00;
  wire [31:0] state;
  wire [31:0] final_crc;

  always #5 clk = ~clk;

  link_crc32c dut (
    .clk_i(clk),
    .resetn_i(resetn),
    .clear_i(clear),
    .valid_i(valid),
    .data_i(data),
    .state_o(state),
    .final_crc_o(final_crc)
  );

  task automatic send_byte(input byte value);
    begin
      for (int pair = 0; pair < 4; pair++) begin
        @(negedge clk);
        valid = 1'b1;
        data[0] = value[pair*2];
        data[1] = value[pair*2+1];
        @(posedge clk);
      end
      @(negedge clk);
      valid = 1'b0;
      data = 2'b00;
    end
  endtask

  initial begin
    repeat (2) @(posedge clk);
    resetn = 1'b1;
    @(negedge clk);
    clear = 1'b1;
    @(posedge clk);
    @(negedge clk);
    clear = 1'b0;
    send_byte("1"); send_byte("2"); send_byte("3");
    send_byte("4"); send_byte("5"); send_byte("6");
    send_byte("7"); send_byte("8"); send_byte("9");
    @(posedge clk);
    if (final_crc !== 32'hE3069283)
      $fatal(1, "CRC32C KAT mismatch got %08x", final_crc);
    $display("TB_LINK_CRC32C=PASS");
    $finish;
  end
endmodule
