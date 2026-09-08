`timescale 1ns/1ps

// Forwarded-clock generator and the single output-enable owner for one
// endpoint.  Normal start/stop uses an explicit low guard cycle: T is lowered
// while the ODDRE1 has been held at zero, and T is raised only after waveform
// generation has been disabled for a complete parent cycle.
module link_clock_oe (
  input  wire parent_clk_i,
  input  wire resetn_i,
  input  wire protocol_t_i,
  input  wire safety_kill_i,
  output wire forwarded_clock_o,
  output wire owner_t_o
);
  typedef enum logic [2:0] {
    ST_OFF, ST_ARM_GUARD, ST_RUN, ST_STOP_GUARD_1, ST_STOP_GUARD_2
  } oe_state_t;
  oe_state_t state;
  logic protocol_t_parent;
  logic waveform_enable;

  // Both stages asynchronously set toward high impedance.  A removed kill is
  // accepted only after two parent-clock rising edges; it can never enable a
  // pad asynchronously.
  (* ASYNC_REG = "TRUE" *) logic [1:0] safety_t_sync;

  always_ff @(posedge parent_clk_i or negedge resetn_i or posedge safety_kill_i) begin
    if (!resetn_i || safety_kill_i) begin
      state <= ST_OFF;
      protocol_t_parent <= 1'b1;
      waveform_enable <= 1'b0;
    end else begin
      case (state)
        ST_OFF: begin
          waveform_enable <= 1'b0;
          if (!protocol_t_i && !safety_t_sync[1]) begin
            protocol_t_parent <= 1'b0;
            state <= ST_ARM_GUARD;
          end else begin
            protocol_t_parent <= 1'b1;
          end
        end
        ST_ARM_GUARD: begin
          if (protocol_t_i) begin
            protocol_t_parent <= 1'b1;
            waveform_enable <= 1'b0;
            state <= ST_OFF;
          end else begin
            waveform_enable <= 1'b1;
            state <= ST_RUN;
          end
        end
        ST_RUN: begin
          if (protocol_t_i) begin
            waveform_enable <= 1'b0;
            state <= ST_STOP_GUARD_1;
          end
        end
        ST_STOP_GUARD_1: begin
          waveform_enable <= 1'b0;
          state <= ST_STOP_GUARD_2;
        end
        ST_STOP_GUARD_2: begin
          waveform_enable <= 1'b0;
          protocol_t_parent <= 1'b1;
          state <= ST_OFF;
        end
        default: begin
          waveform_enable <= 1'b0;
          protocol_t_parent <= 1'b1;
          state <= ST_OFF;
        end
      endcase
    end
  end

  always_ff @(posedge parent_clk_i or negedge resetn_i or posedge safety_kill_i) begin
    if (!resetn_i)
      safety_t_sync <= 2'b11;
    else if (safety_kill_i)
      safety_t_sync <= 2'b11;
    else if (protocol_t_i)
      safety_t_sync <= {safety_t_sync[0], 1'b0};
  end

  assign owner_t_o = protocol_t_parent | safety_t_sync[1];

  ODDRE1 #(
    .IS_C_INVERTED(1'b0),
    .IS_D1_INVERTED(1'b0),
    .IS_D2_INVERTED(1'b0),
    .SIM_DEVICE("ULTRASCALE_PLUS"),
    .SRVAL(1'b0)
  ) forwarded_clock_ddr (
    .Q(forwarded_clock_o),
    .C(parent_clk_i),
    .D1(1'b0),
    .D2(waveform_enable),
    .SR(~resetn_i)
  );
endmodule
