{
  description = "Oreo cursors with reversible, one-shot transition assets";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/104240a772428cc2e20d8fd86c9ddbb886bbaff2";
  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      eachSystem = nixpkgs.lib.genAttrs systems;
      tools = pkgs: [
        (pkgs.ruby.withPackages (ps: [
          ps.rexml
          ps.minitest
        ]))
        pkgs.imagemagick
        pkgs.inkscape
        pkgs.xcursorgen
      ];
    in
    {
      packages = eachSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          niri = pkgs.niri.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [ ./patches/niri-cursor-transitions.patch ];
            doCheck = true;
            cargoTestFlags = [
              "--lib"
              "cursor::tests"
            ];
          });
          default = pkgs.stdenvNoCC.mkDerivation {
            pname = "animated-oreo-cursors";
            version = "0.1.0";
            src = self;
            nativeBuildInputs = tools pkgs;
            buildPhase = ''
              export INKSCAPE_PROFILE_DIR="$TMPDIR/inkscape"
              ruby generator/transitions.rb \
                --base-theme ${pkgs.oreo-cursors-plus}/share/icons/oreo_spark_black_bordered_cursors \
                --output build/animated_oreo_spark_black_bordered_cursors
              ruby tests/test_transitions.rb
            '';
            installPhase = ''
              mkdir -p "$out/share/icons"
              cp -r build/animated_oreo_spark_black_bordered_cursors "$out/share/icons/"
              install -Dm644 LICENSE "$out/share/licenses/animated-oreo-cursors/LICENSE"
            '';
            meta.license = pkgs.lib.licenses.gpl2Only;
          };
        }
      );
      devShells = eachSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell { packages = tools pkgs; };
        }
      );
    };
}
