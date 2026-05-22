{
  description = "Remote Vivado build helper for HDL projects";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }: {
    lib.makeHdlApps = import ./lib/makeHdlApps.nix;

    templates.default = {
      path        = ./templates/hdl-default;
      description = "HDL project with ichika remote Vivado synthesis and implementation";
    };
  };
}
