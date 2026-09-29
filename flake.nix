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

        # A symlink mirror of the system CommandLineTools exposing only one
        # known-good SDK. Swift 6.4's default build system enumerates every
        # SDK under $DEVELOPER_DIR/SDKs and fails outright ("Unknown error
        # parsing property list") on a stale stub like MacOSX15.5.sdk with no
        # SDKSettings.plist. The 27.0 SDK is skipped too: its SwiftUI needs a
        # SwiftUIMacros plugin that CLT doesn't ship. The directory must be
        # named `CommandLineTools` or xcrun won't accept it as a developer dir.
        # Bump `sdk` when CLT updates.
        cltDir = "/Library/Developer/CommandLineTools";
        sdk = "MacOSX26.5.sdk";
        developerDir = pkgs.runCommand "monica-developer-dir" { } ''
          mkdir -p $out/CommandLineTools/SDKs
          ln -s ${cltDir}/usr $out/CommandLineTools/usr
          ln -s ${cltDir}/Library $out/CommandLineTools/Library
          ln -s ${cltDir}/SDKs/${sdk} $out/CommandLineTools/SDKs/${sdk}
          ln -s ${sdk} $out/CommandLineTools/SDKs/MacOSX.sdk
        '';
      in
      {
        # Dev tooling only. The Swift compiler itself comes from the system
        # Xcode Command Line Tools (nixpkgs Swift on macOS is unreliable) —
        # build with `swift build` / `make build`. This shell just provides
        # swift-format, plus MONICA_DEVELOPER_DIR (see `developerDir`), which
        # the Makefile and build-app.sh use as DEVELOPER_DIR when set.
        devShells.default = pkgs.mkShell {
          packages = [ pkgs.swift-format ];
          MONICA_DEVELOPER_DIR = "${developerDir}/CommandLineTools";
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
