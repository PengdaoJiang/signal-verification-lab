# Stateful queue and credit model

These are the original queue engine and two-endpoint software model, with a separately extracted completion-event checker. They cover byte-range allocation, conserved credit tokens, virtual-output queues, calendar arbitration, backend acceptance/completion and release/cancellation ownership. No protocol documents or hardware design archive is distributed.

`python -m unittest discover -s streaming -p "test_*.py"` exercises conservation, byte-exact memory transfers, fragmentation and the independent service checker using original synthetic inputs.

`queue_service.py` and `host_pair.py` are a transaction-level model, not a DDR timing model, network driver, implemented FPGA netlist or measured throughput result. Their defaults are explicit model inputs; a hardware adapter must separately establish the assumed service and reset contract. The original product-budget acceptance scripts are not copied, so model execution cannot be confused with product sign-off.
