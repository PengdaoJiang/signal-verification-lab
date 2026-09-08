`timescale 1ns/1ps

module tb_link_clock_oe;
  logic parent_clk = 1'b0;
  logic resetn = 1'b0;
  logic protocol_t = 1'b1;
  logic safety_kill = 1'b0;
  wire forwarded_clock;
  wire owner_t;
  wire pad_clock = owner_t ? 1'bz : forwarded_clock;

  int rising_edges = 0;
  int falling_edges = 0;
  realtime last_transition = 0.0;
  realtime width;
  bit checking_width = 1'b0;

  always #10 parent_clk = ~parent_clk;

  link_clock_oe dut (
    .parent_clk_i(parent_clk),
    .resetn_i(resetn),
    .protocol_t_i(protocol_t),
    .safety_kill_i(safety_kill),
    .forwarded_clock_o(forwarded_clock),
    .owner_t_o(owner_t)
  );

  always @(posedge pad_clock) begin
    if (pad_clock === 1'b1) begin
      rising_edges++;
      if (checking_width) begin
        width = $realtime - last_transition;
        if (width < 9.999) $fatal(1, "runt low pulse %0.3f ns", width);
      end
      last_transition = $realtime;
      checking_width = 1'b1;
    end
  end

  always @(negedge pad_clock) begin
    if (pad_clock === 1'b0) begin
      falling_edges++;
      if (checking_width) begin
        width = $realtime - last_transition;
        if (width < 9.999) $fatal(1, "runt high pulse %0.3f ns", width);
      end
      last_transition = $realtime;
    end
  end

  always @(owner_t) begin
    if (resetn && !safety_kill && (forwarded_clock !== 1'b0))
      $fatal(1, "normal T transition while forwarded clock=%b was not low protocol=%b state=%0d wave=%b owner=%b",
        forwarded_clock, protocol_t, dut.state, dut.waveform_enable, owner_t);
  end

  task automatic normal_window(input int start_phase_ns, input int stop_phase_ns);
    int rise_before;
    int fall_before;
    begin
      protocol_t = 1'b1;
      repeat (3) @(posedge parent_clk);
      #(start_phase_ns);
      protocol_t = 1'b0;
      rise_before = rising_edges;
      fall_before = falling_edges;
      repeat (8) @(posedge parent_clk);
      @(posedge parent_clk);
      #(stop_phase_ns);
      protocol_t = 1'b1;
      repeat (4) @(posedge parent_clk);
      if (!owner_t) $fatal(1, "owner_t failed to stop start=%0d stop=%0d", start_phase_ns, stop_phase_ns);
      if ((rising_edges - rise_before) < 6 || (falling_edges - fall_before) < 6)
        $fatal(1, "insufficient complete pulses start=%0d stop=%0d", start_phase_ns, stop_phase_ns);
    end
  endtask

  initial begin
    repeat (3) @(posedge parent_clk);
    resetn = 1'b1;
    repeat (3) @(posedge parent_clk);
    if (!owner_t) $fatal(1, "default must be Hi-Z");

    for (int start_phase = 0; start_phase < 40; start_phase++)
      normal_window(start_phase, (start_phase * 17 + 3) % 40);

    protocol_t = 1'b0;
    repeat (5) @(posedge parent_clk);
    safety_kill = 1'b1;
    #1;
    if (!owner_t) $fatal(1, "safety kill did not asynchronously force Hi-Z");
    // Clearing a fault does not constitute a fresh arm.
    protocol_t = 1'b1;
    safety_kill = 1'b0;
    @(posedge parent_clk);
    if (!owner_t) $fatal(1, "safety kill released too early");
    repeat (2) @(posedge parent_clk);
    if (!owner_t) $fatal(1, "kill clear enabled without fresh arm");

    protocol_t = 1'b0;
    repeat (3) @(posedge parent_clk);
    if (owner_t) $fatal(1, "fresh arm failed after qualified clear");

    protocol_t = 1'b1;
    repeat (2) @(posedge parent_clk);
    $display("TB_LINK_CLOCK_OE=PASS");
    $finish;
  end
endmodule
