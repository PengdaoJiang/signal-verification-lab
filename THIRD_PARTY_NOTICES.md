# Third-party notices

Repository-authored RTL, Python, C, testbenches and documentation are released under the root MIT license. The source-derived modules were developed with Codex assistance and prepared for public distribution by the author.

External dependencies are not included in that license grant:

- AMD Vivado/XSim and installed XPM/device primitive libraries retain their vendor licenses. This repository instantiates `xpm_fifo_async`, `xpm_cdc_handshake`, `xpm_cdc_single`, `xpm_memory_sdpram` and `ODDRE1`, but does not redistribute their implementation or `glbl.v`.
- No CMAC, GT, VIO or other generated vendor IP source/output product is bundled.
- Python, C compilers, Icarus Verilog and referenced GitHub Actions retain their own licenses.

Original protocol documents/photos, third-party papers, licensed MATLAB examples, production captures, pin constraints and bitstreams are not part of this release.
