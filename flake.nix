{
  description = "mgch timers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        package = pkgs.stdenv.mkDerivation {
          pname = "mgch_timers";
          version = "0.0.0";

          src = ./.;

          nativeBuildInputs = [
            pkgs.zig
          ];

          buildPhase = ''
            zig build -Doptimize=ReleaseSafe
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp zig-out/bin/mgch_timers $out/bin/
          '';
        };

      in
      {
        packages.default = package;

        apps.default = {
          type = "app";
          program = "${package}/bin/mgch_timers";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.zig
          ];
        };
      }
    );
}
