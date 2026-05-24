{
  description = "Remote Vivado build helper for HDL projects";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system}; in {
        packages.convert = pkgs.writers.writePython3Bin "convert" {} ''
          import sys
          import os


          def main():
              if len(sys.argv) < 2:
                  print("Usage: convert <file.bin>", file=sys.stderr)
                  sys.exit(1)

              input_file = sys.argv[1]
              output_file = os.path.splitext(input_file)[0] + ".coe"

              with open(input_file, "rb") as f:
                  data = f.read()

              with open(output_file, "w") as f:
                  f.write("memory_initialization_radix=16;\n")
                  f.write("memory_initialization_vector=\n")
                  hex_vals = [f"{b:02x}" for b in data]
                  for i in range(0, len(hex_vals), 16):
                      chunk = hex_vals[i:i+16]
                      line = ", ".join(chunk)
                      if i + 16 < len(hex_vals):
                          f.write(line + ",\n")
                      else:
                          f.write(line + "\n")
                  f.write(";\n")

              print(f"Written to {output_file}")


          main()
        '';
      }
    ) // {
      lib.makeHdlApps = import ./lib/makeHdlApps.nix;

      templates.default = {
        path        = ./templates/hdl-default;
        description = "HDL project with ichika remote Vivado synthesis and implementation";
      };
    };
}
