# ichika

Ichika is a Nix flake library for sending FPGA design sources to a remote AMD Vivado machine and running synthesis or implementation there. It is intended for a lightweight development computer that should not spend its CPU and memory on Vivado runs.

Ichika provides two client commands:

```sh
nix run .#synthesize
nix run .#run-impl
```

It supports two build modes:

- RTL mode reads Verilog/SystemVerilog and XDC directly in Vivado non-project mode.
- Project mode reconstructs a Vivado project from checked-in Tcl and sources, then runs the managed `synth_1` and `impl_1` runs. This is the recommended mode for Zynq UltraScale+ block designs.

Ichika handles transfer, remote execution, workspace isolation, and artifact retrieval. It does not install Vivado, configure licensing, author block designs, build processor software, or program hardware.

## Build pipeline

Every invocation performs the following operations:

1. Select the server from `ICHIKA_SERVER`, `serverDns`, or `serverLocal`.
2. Create a unique build ID such as `20260910T142301Z-12345`.
3. Merge the configured local source directories into a temporary staging tree.
4. Exclude configured files such as `.git/`, `.direnv/`, and `artifacts/`.
5. Synchronize the staged tree to a new remote workspace.
6. Upload constraints and the selected Ichika build driver.
7. Start Vivado in batch mode inside the remote workspace.
8. Download the resulting reports and build artifacts.
9. Remove the successful remote workspace unless `keepRemote = true`.

The default remote workspace is:

```text
/var/lib/vivado-remote/<projectName>/<build-id>/
```

Artifacts are downloaded to:

```text
artifacts/<build-id>/
```

Set a stable build ID when another tool needs a deterministic path:

```sh
ICHIKA_BUILD_ID=main nix run .#run-impl
```

Build IDs and project names may contain letters, digits, `.`, `_`, and `-`.

## Quick start: RTL

Create a starter flake:

```sh
nix flake init -t github:kaitotlex/ichika
```

Configure the generated `flake.nix`:

```nix
hdlApps = ichika.lib.makeHdlApps {
  inherit pkgs;
  top = "my_top";
  part = "xczu3eg-sfvc784-1-e";
  sourceDirs = [ "rtl" ];
  constraintsFiles = [ "constraints/pins.xdc" "constraints/timing.xdc" ];
  serverLocal = "10.0.0.228";
  serverUser = "vivado";
};
```

`top` is the HDL module name, not a filename.

Run synthesis or the complete implementation pipeline:

```sh
nix run .#synthesize
nix run .#run-impl
```

RTL synthesis produces:

```text
synth.dcp
timing_synth.rpt
utilization_synth.rpt
vivado.jou
vivado.log
```

RTL implementation produces:

```text
<top>.bit
timing_impl.rpt
utilization_impl.rpt
vivado.jou
vivado.log
```

## Zynq UltraScale+ and block designs

A Zynq UltraScale+ processing system is hardened silicon and is not synthesized as programmable logic. The Vivado block design configures the processing system and describes its connection to PL clocks, resets, interrupts, AXI infrastructure, DMA engines, peripherals, and custom logic.

The recommended development split is:

- Use the Vivado GUI on the x86 workstation to configure the processing system, edit the block design, assign addresses, and validate connections.
- Keep substantial accelerators and custom datapaths as ordinary RTL, using module references or packaged IP where appropriate.
- Export a reproducible project Tcl file after GUI changes.
- Store that Tcl file, the block-design Tcl or BD source, RTL, XDC, initialization files, and custom IP sources in the repository.
- Reconstruct the project and perform synthesis and implementation on the remote server.

Do not use an XSA as the build input. An XSA is a downstream hardware-platform output for Vitis and software tooling.

### Recommended repository layout

```text
flake.nix
rtl/
constraints/
vivado/
  project.tcl
  design_bd.tcl
  ip/
```

Generated caches and run outputs should normally remain untracked:

```text
.Xil/
*.cache/
*.gen/
*.hw/
*.ip_user_files/
*.runs/
*.sim/
artifacts/
vivado.jou
vivado.log
```

Some third-party or encrypted IP may require committed generated products. Treat that as an IP-specific exception rather than copying the entire GUI project by default.

### Project-mode configuration

Use one source root when preserving repository-relative paths matters:

```nix
hdlApps = ichika.lib.makeHdlApps {
  inherit pkgs;
  top = "system_wrapper";
  part = "xczu3eg-sfvc784-1-e";
  projectName = "aup-zu3-system";
  sourceDirs = [ "." ];
  projectTcl = "vivado/project.tcl";
  jobs = 16;
  serverLocal = "10.0.0.228";
  serverDns = "vivado.example.com";
  serverUser = "vivado";
  artifactDir = "artifacts";
};
```

`projectTcl` is a path inside the uploaded source tree. Use a string path relative to the local runtime working directory. Do not use a Nix path such as `./vivado/project.tcl`, because that path refers to the Nix store and is not automatically part of the uploaded tree.

The project Tcl must:

1. Create or open a Vivado project.
2. Select the configured FPGA part.
3. Configure the board part and custom IP repositories when required.
4. Add all RTL, constraints, block-design inputs, and IP inputs.
5. Recreate or load the block design.
6. Validate the block design and generate its targets.
7. Generate and add the HDL wrapper.
8. Leave the project open.
9. Define the standard `synth_1` and `impl_1` runs.

Ichika passes `--origin_dir <remote-source-directory>` to the project Tcl. A Tcl file generated by Vivado `write_project_tcl` can use this to resolve repository-relative sources.

From the Vivado GUI Tcl console, a starting point is:

```tcl
write_project_tcl -force -no_copy_sources ./vivado/project.tcl
```

If the block design is maintained separately, export it after selecting or opening the design:

```tcl
write_bd_tcl -force ./vivado/design_bd.tcl
```

A block-design Tcl file by itself is not a complete project build script. The project Tcl must create the project, source the block-design Tcl, generate targets and the wrapper, add constraints and RTL, and create the runs.

After export, inspect `project.tcl` for absolute workstation paths. Every required input must either be relative to the supplied origin directory or available through an explicitly configured server path. A clean reconstruction from a new directory on the workstation is the best check before sending the design remotely.

### Project-mode synthesis

`nix run .#synthesize` performs these Vivado operations:

1. Delete and recreate the build directory inside the unique remote workspace.
2. Source `projectTcl` with the uploaded source tree as `--origin_dir`.
3. Confirm that the project remains open and defines `synth_1` and `impl_1`.
4. Confirm that the project's FPGA part exactly matches `part`.
5. Set the source-set top to `top` and update compile order.
6. Reset and launch `synth_1` using the configured number of jobs.
7. Wait for synthesis and reject an incomplete run.
8. Open the synthesized design and export its checkpoint, timing report, and utilization report.

The downloaded project-mode synthesis artifacts are:

```text
synth.dcp
timing_synth.rpt
utilization_synth.rpt
vivado.jou
vivado.log
```

### Project-mode implementation

`nix run .#run-impl` first performs the project-mode synthesis process and then:

1. Launches `impl_1` through `write_bitstream`.
2. Waits for implementation and rejects an incomplete run.
3. Opens the implemented design.
4. Writes the implemented DCP.
5. Writes timing, utilization, DRC, methodology, power, and clock-utilization reports.
6. Writes a normalized `<top>.bit` artifact.
7. Writes `<top>.xsa` with the bitstream included.

The downloaded project-mode implementation artifacts are:

```text
<top>.bit
<top>.xsa
synth.dcp
impl.dcp
timing_synth.rpt
utilization_synth.rpt
timing_impl.rpt
utilization_impl.rpt
drc_impl.rpt
methodology_impl.rpt
power_impl.rpt
clock_utilization_impl.rpt
vivado.jou
vivado.log
```

### Version and dependency requirements

The workstation and server should use the exact same Vivado release and patch level. This matters for:

- Zynq UltraScale+ processing-system configuration
- block-design schema
- IP catalog versions
- generated output products
- project migration
- checkpoint compatibility
- encrypted or licensed IP

The server must also have any required board files, custom IP repositories, and licenses. If the project Tcl sets a `board_part`, that board definition must exist on the server. A raw FPGA `part` is sufficient only when the project does not depend on board metadata or board automation.

## RTL mode details

The built-in RTL flow is intentionally small and uses Vivado non-project mode.

It recursively reads only lowercase `.v` and `.sv` files. It does not automatically support:

- VHDL
- XCI files
- BD files
- XPR files
- input DCP files
- EDIF netlists
- source libraries
- Verilog include directories
- Verilog macro definitions
- explicit compile ordering
- custom synthesis or implementation strategies

All discovered Verilog files are read with `read_verilog -sv`. Every uploaded XDC in the remote workspace is read before `synth_design`.

The synthesis sequence is:

```tcl
read_verilog
read_xdc
synth_design
write_checkpoint
report_timing_summary
report_utilization
```

The implementation sequence starts from RTL again and does not reuse the standalone synthesis checkpoint:

```tcl
read_verilog
read_xdc
synth_design
opt_design
place_design
route_design
report_timing_summary
report_utilization
write_bitstream
```

Use custom `synthTcl` and `implTcl` scripts when a non-project RTL flow needs other languages, source properties, compile ordering, definitions, checkpoints, or implementation directives. `projectTcl` cannot be combined with custom build-driver scripts.

## Configuration reference

| Option | Default | Description |
|--------|---------|-------------|
| `pkgs` | required | nixpkgs package set for the current system |
| `top` | required | HDL top module name |
| `part` | required | Exact Vivado FPGA part string |
| `sourceDirs` | `rtlDirs` | Runtime source directories merged into the uploaded source tree |
| `rtlDirs` | `[ ]` | Compatibility name for `sourceDirs` |
| `constraintsFiles` | `[ "constraints.xdc" ]` | RTL-mode XDC files copied to the workspace root |
| `serverLocal` | required | Default server address |
| `serverDns` | `""` | Alternate server selected with `ICHIKA_USE_DNS=1` |
| `serverUser` | `"runner"` | Remote SSH account |
| `sshKey` | `""` | SSH private-key path; empty uses normal SSH-agent/config behavior |
| `workBase` | `"/var/lib/vivado-remote"` | Remote workspace base |
| `projectName` | `top` | Remote project namespace |
| `projectTcl` | `null` | Uploaded-tree-relative project reconstruction Tcl; enables project mode |
| `jobs` | `8` | Vivado managed-run parallel job count |
| `artifactDir` | `"artifacts"` | Local base directory for downloaded build-ID directories |
| `rsyncExclude` | common generated paths | Patterns omitted while staging sources |
| `keepRemote` | `false` | Preserve successful remote workspaces |
| `synthTcl` | `null` | Custom RTL-mode synthesis driver |
| `implTcl` | `null` | Custom RTL-mode implementation driver |
| `implTclArgs` | `[ ]` | Extra arguments passed to a custom implementation driver |

At least one `sourceDirs` or `rtlDirs` entry is required.

The default exclusions are:

```nix
[ ".git/" ".direnv/" "artifacts/" "result" ]
```

Directories are merged in listed order. Later directories replace colliding files from earlier directories. The merged tree is synchronized once, avoiding deletion between source directories.

## Server selection

Override the configured address for one command:

```sh
ICHIKA_SERVER=192.168.1.50 nix run .#run-impl
```

Select `serverDns`:

```sh
ICHIKA_USE_DNS=1 nix run .#run-impl
```

SSH uses batch authentication and accepts a previously unseen host key. Configure a key or SSH agent before building; interactive password authentication is not supported by the generated command.

## Server setup

Server provisioning is outside Ichika. The server must provide:

- SSH access for `serverUser`
- `rsync`
- a writable `workBase`
- Vivado available as `vivado` in a noninteractive SSH session
- the correct Vivado release and patch
- a working Vivado license
- required board definitions and custom IP

One supported deployment approach is the `hdlBuild` service from [xilinx-flake](https://github.com/MIT-OpenCompute/xilinx-flake):

```nix
services.vivadoServer = {
  enable = true;
  installDir = "/opt/Xilinx";
  version = "2025.2";

  hdlBuild = {
    enable = true;
    authorizedKeys = [ "ssh-ed25519 AAAA... dev@machine" ];
    licenseFile = "@localhost";
    openFirewall = true;
  };
};
```

Confirm the noninteractive environment before using Ichika:

```sh
ssh vivado@build-server 'vivado -version'
```

## Scope boundaries

Ichika covers remote Vivado synthesis and implementation. It does not currently provide:

- Vivado installation or license management
- board-file installation
- automatic IP upgrades
- GUI block-design editing
- simulation, linting, or formal verification orchestration
- timing-closure optimization
- a timing-slack pass/fail policy
- critical-DRC gating beyond run completion
- incremental implementation
- remote scheduling or a multi-user queue
- Vitis workspace or application builds
- FSBL, PMU firmware, TF-A, U-Boot, Linux, or device-tree builds
- BOOT.BIN or SD-card image generation
- hardware-manager programming
- remote workspace retention policies beyond `keepRemote`

The starter development shell includes Verilator, Icarus Verilog, Yosys, svlint, GTKWave, and Make, but Ichika does not invoke those tools automatically.

Failed builds retain their remote workspace because artifact download and successful cleanup are never reached. Use the path printed at upload time together with the Vivado log to investigate the failure.
