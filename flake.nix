{
  description = "Claude API usage monitor with history, sparklines, and projections";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        runtimeDeps = with pkgs; [ jq curl coreutils bash bc ];
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "claude-usage-statusline";
          version = "0.1.0";

          src = ./.;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          installPhase = ''
            mkdir -p $out/lib/claude-usage $out/share/claude-usage/views $out/bin

            # Install library files
            cp lib/*.sh $out/lib/claude-usage/

            # Install view files
            cp views/*.sh $out/share/claude-usage/views/

            # Install and patch entrypoint
            cp bin/claude-usage $out/bin/claude-usage
            chmod +x $out/bin/claude-usage

            substituteInPlace $out/bin/claude-usage \
              --replace '@LIB_DIR@' "$out/lib/claude-usage" \
              --replace '@VIEWS_DIR@' "$out/share/claude-usage/views"

            wrapProgram $out/bin/claude-usage \
              --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}
          '';

          meta = with pkgs.lib; {
            description = "Claude API usage monitor with history and projections";
            license = licenses.mit;
            platforms = platforms.unix;
            mainProgram = "claude-usage";
          };
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/claude-usage";
        };

        overlays.default = final: prev: {
          claude-usage-statusline = self.packages.${system}.default;
        };
      }
    );
}
