{
  description = "monica — menu bar / HUD / Spotlight watcher+switcher for tmux AI agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        # Dev tooling only. The Swift compiler itself comes from the system
        # Xcode Command Line Tools (nixpkgs Swift on macOS is unreliable) —
        # build with `swift build` / `make build`. This shell just provides
        # swift-format.
        devShells.default = pkgs.mkShell {
          packages = [ pkgs.swift-format ];
          shellHook = ''
            echo "monica devshell · swift-format $(swift-format --version 2>/dev/null || echo '?')"
            echo "  build:  make build"
            echo "  run:    make run"
            echo "  app:    make app"
            echo "  link:   make link   (symlink monica.app into /Applications)"
          '';
        };
      }
    );
}
