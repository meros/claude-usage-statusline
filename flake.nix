{
  description = "Claude plan usage in your statusline, with history, sparklines and projections";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        # Tools the scripts call. flock (util-linux) is optional: without it
        # parallel statuslines can each call the API once.
        runtimeDeps = with pkgs; [ bash coreutils curl gawk git gnused jq ]
          ++ lib.optional stdenv.isLinux util-linux;

        claude-usage = pkgs.stdenv.mkDerivation {
          pname = "claude-usage-statusline";
          version = "0.2.0";
          src = ./.;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          installPhase = ''
            mkdir -p $out/lib/claude-usage $out/share/claude-usage/views $out/bin
            cp lib/*.sh $out/lib/claude-usage/
            cp views/*.sh $out/share/claude-usage/views/
            cp bin/claude-usage $out/bin/claude-usage
            chmod +x $out/bin/claude-usage

            substituteInPlace $out/bin/claude-usage \
              --replace-fail '@LIB_DIR@' "$out/lib/claude-usage" \
              --replace-fail '@VIEWS_DIR@' "$out/share/claude-usage/views"

            wrapProgram $out/bin/claude-usage \
              --prefix PATH : ${lib.makeBinPath runtimeDeps}
          '';

          meta = with lib; {
            description = "Claude plan usage in your statusline, with history and projections";
            homepage = "https://github.com/meros/claude-usage-statusline";
            license = licenses.mit;
            platforms = platforms.unix;
            mainProgram = "claude-usage";
          };
        };
      in
      {
        packages.default = claude-usage;

        apps.default = {
          type = "app";
          program = "${claude-usage}/bin/claude-usage";
        };

        # nix flake check: the test suite and shellcheck.
        checks = {
          tests = pkgs.runCommand "claude-usage-tests"
            {
              nativeBuildInputs = runtimeDeps ++ (with pkgs; [ findutils gnugrep tzdata util-linux ]);
              TZDIR = "${pkgs.tzdata}/share/zoneinfo";
            } ''
            cp -r ${./.} src
            chmod -R u+w src
            patchShebangs src
            bash src/tests/run-tests.sh
            touch $out
          '';

          shellcheck = pkgs.runCommand "claude-usage-shellcheck"
            { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
            cd ${./.}
            shellcheck -x bin/claude-usage install.sh scripts/*.sh tests/*.sh tests/lib/*.sh
            shellcheck -x -e SC2034,SC2154 lib/*.sh views/*.sh
            touch $out
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = runtimeDeps ++ [ pkgs.shellcheck ];
        };
      }
    ) // {
      overlays.default = final: prev: {
        claude-usage-statusline = self.packages.${prev.stdenv.hostPlatform.system}.default;
      };
    };
}
