# Verification design

This document covers the independent Python/C FIR exercise. The source-derived FPGA datapaths are documented separately in `rtl-architecture.md`.

## Start with an exact contract

The example deliberately uses a short, ordinary FIR. Its purpose is to make implementation disagreements observable, not to introduce a new filter algorithm.

Q1.15 values are represented by integers. Each output is the three-product sum divided by 32768 with floor rounding, then saturated to a signed 16-bit integer. The accumulator is 64-bit: a three-product sum can exceed a signed 32-bit range for valid inputs and coefficients.

Negative rounding is explicit. Relying on a right shift of a negative signed value would obscure portability; relying on C integer division alone would use truncation toward zero rather than the specified floor. The implementation handles that distinction directly.

## Keep the reference structurally different

The Python reference computes an indexed convolution over the input history. The C implementation advances a two-sample mutable delay state. This makes a shared state-update bug less likely than using a line-for-line translation as the oracle. Both still implement the same stated contract; agreement is evidence within that contract, not a proof of all possible behavior.

## Verify the state machine as well as arithmetic

For every generated case:

1. Compare the complete C output with the independent integer reference.
2. Repeat the same data through uneven chunks without resetting state.
3. Reset the C state and repeat the run, checking that no prior samples leak through.

Directed inputs cover impulses, signed extremes, alternating values, rounding boundaries, and saturation. Seeded random inputs exercise additional combinations. The CLI requires a real compiled library; missing native code is an error, not a silent Python fallback.

## Test the checker

The comparison path must detect a one-bit error, a missing sample, and a duplicated sample. Length checks and first-mismatch reporting distinguish alignment failures from ordinary numeric disagreements. These injected faults validate those detection paths; they are not an exhaustive mutation score.

## Preserve the evidence boundary

The machine-readable receipt ties results to source and library hashes, seed, platform, Python version, case count, sample count, and checks. Generated inputs avoid external datasets and make the experiment repeatable.

An RTL or hardware adapter could reuse the integer contract and vector generator, but would require its own build identifiers, clocks/resets, handshakes, captured outputs, and timing evidence. This repository currently reports Python/C verification only.
