# ichika

Nix flake library for sending HDL to a remote Vivado build server. Add it to any HDL project to get `nix run .#synthesize` and `nix run .#run-impl` without installing Vivado locally.

## How it works

`nix run .#synthesize` — rsyncs your RTL to the server, runs Vivado synthesis in batch mode, prints timing/utilization reports.

`nix run .#run-impl` — rsyncs your RTL, runs the full pipeline (synth → opt → place → route → write_bitstream), copies `<top>.bit` back to your working directory.

Sources are rsynced from `$PWD` on every run, so edits are picked up immediately without rebuilding the flake.

## Quick start

```sh
nix flake init -t github:kaitotlex/ichika
```

Edit the generated `flake.nix`:

```nix
hdlApps = ichika.lib.makeHdlApps {
  inherit pkgs;
  top         = "my_top";
  part        = "xczu3eg-sfvc784-1-e";
  rtlDirs     = [ "rtl" ];
  serverLocal = "10.0.0.228/24";
};
```

Then run:

```sh
nix run .#synthesize
nix run .#run-impl
```

## Adding to an existing flake

```nix
inputs.ichika.url = "github:kaitotlex/ichika";

# inside eachDefaultSystem:
apps = ichika.lib.makeHdlApps {
  inherit pkgs;
  top         = "cpu_top";
  part        = "xczu3eg-sfvc784-1-e";
  rtlDirs     = [ "rtl" ];
  serverLocal = "10.0.0.228";
};
```

## `makeHdlApps` options

| Option | Default | Description |
|--------|---------|-------------|
| `pkgs` | required | nixpkgs for the current system |
| `top` | required | Top module name |
| `part` | required | Vivado FPGA part string |
| `rtlDirs` | required | List of RTL source directories (relative to `$PWD`) |
| `constraintsFile` | `"constraints.xdc"` | XDC file path; skipped if absent |
| `serverLocal` | required | LAN IP of the build server |
| `serverDns` | `""` | Public DNS name (use with `ICHIKA_USE_DNS=1`) |
| `serverUser` | `"vivado"` | SSH user on the server |
| `sshKey` | `""` | SSH key path; empty uses the SSH agent |
| `workBase` | `"/var/lib/vivado-remote"` | Base directory for build artifacts on the server |

## Switching server addresses

```sh
ICHIKA_SERVER=192.168.1.50 nix run .#run-impl   # explicit override
ICHIKA_USE_DNS=1 nix run .#run-impl              # use serverDns
```

## Server setup

The server must run NixOS with `xilinx-flake` and have the `hdlBuild` service enabled:

```nix
services.vivadoServer = {
  enable     = true;
  installDir = "/home/kaitotlex/Xilinx";
  version    = "2025.2";

  hdlBuild = {
    enable         = true;
    authorizedKeys = [ "ssh-ed25519 AAAA... dev@machine" ];
    licenseFile    = "@localhost";
    openFirewall   = true;
  };
};
```

See [xilinx-flake](https://github.com/kaitotlex/xilinx-flake) for the full server module documentation.
