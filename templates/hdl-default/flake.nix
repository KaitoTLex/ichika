{
  description = "HDL project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    ichika.url = "github:kaitotlex/ichika";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ichika,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        hdlApps = ichika.lib.makeHdlApps {
          inherit pkgs;
          top = "my_top";
          part = "xczu3eg-sfvc784-1-e";
          rtlDirs = [ "rtl" ];
          serverLocal = "10.0.0.228";
          serverUser = "vivado"; # set to your SSH user on the build server
          # serverDns        = "build.example.com";
          # sshKey           = "~/.ssh/id_ed25519";
          # constraintsFiles = [ "timing.xdc" "pins.xdc" ];
          # implTcl          = ./custom_impl.tcl;
          # implTclArgs      = [ "/remote/path/constraints.xdc" ];
        };
      in
      {
        apps = hdlApps;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            verilator
            iverilog
            yosys
            svlint
            gtkwave
            gnumake
          ];
        };
      }
    );
}
