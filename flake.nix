{
  description = "Effet OCaml development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          ocamlPackages = pkgs.ocamlPackages;
          oxCamlSwitch = "5.2.0+ox";
          oxCamlOpamRoot = ".opam-oxcaml";
          oxCamlSetup = pkgs.writeShellApplication {
            name = "effet-oxcaml-init";
            runtimeInputs = [
              pkgs.git
              pkgs.opam
            ];
            text = ''
              switch_name="''${1:-${oxCamlSwitch}}"
              repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
              cd "$repo_root"

              export OPAMROOT="''${OPAMROOT:-$repo_root/${oxCamlOpamRoot}}"
              export OPAMYES=1

              if [ ! -d "$OPAMROOT" ]; then
                opam init --bare --disable-sandboxing --no-setup --yes
              fi

              if ! opam switch list --short | grep -Fxq "$switch_name"; then
                opam switch create "$switch_name" \
                  --repos ox=git+https://github.com/oxcaml/opam-repository.git,default \
                  --assume-depexts \
                  --yes
              fi

              export OPAMSWITCH="$switch_name"
              eval "$(opam env --switch "$switch_name" --set-switch)"
              opam install . --deps-only --with-test --assume-depexts --yes

              echo "OxCaml switch is ready: $switch_name"
              echo "Enter it with: nix develop .#oxcaml"
            '';
          };
          oxCamlShippedTests = pkgs.writeShellApplication {
            name = "effet-oxcaml-test-shipped";
            runtimeInputs = [
              pkgs.opam
            ];
            text = ''
              switch_name="''${1:-${oxCamlSwitch}}"
              repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
              cd "$repo_root"

              export OPAMROOT="''${OPAMROOT:-$repo_root/${oxCamlOpamRoot}}"
              export OPAMSWITCH="$switch_name"
              eval "$(opam env --switch "$switch_name" --set-switch)"

              dune build \
                packages/effet \
                packages/effet-otel \
                packages/effet-schema \
                packages/effet-stream \
                packages/ppx_effet \
                packages/effet/test \
                packages/effet-otel/test \
                packages/effet-schema/test \
                packages/effet-stream/test \
                packages/ppx_effet/test

              dune runtest \
                packages/effet \
                packages/effet-otel \
                packages/effet-schema \
                packages/effet-stream \
                packages/ppx_effet \
                --force
            '';
          };
          oxCamlHostPackages =
            [
              pkgs.autoconf
              pkgs.cacert
              pkgs.curl
              pkgs.git
              pkgs.gnumake
              pkgs.m4
              pkgs.opam
              pkgs.patch
              pkgs.pkg-config
              pkgs.unzip
              pkgs.which
              oxCamlSetup
              oxCamlShippedTests
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              pkgs.gmp
              pkgs.libev
              pkgs.libffi
              pkgs.openssl
              pkgs.zlib
            ];
        in
        {
          default = pkgs.mkShell {
            packages = [
              ocamlPackages.ocaml
              ocamlPackages.dune_3
              ocamlPackages.findlib
              ocamlPackages.eio
              ocamlPackages.eio_main
              ocamlPackages.alcotest
              ocamlPackages.yojson
              ocamlPackages.ppxlib
            ];
          };

          oxcaml = pkgs.mkShell {
            packages = oxCamlHostPackages;

            shellHook = ''
              if repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
                export OPAMROOT="''${OPAMROOT:-$repo_root/${oxCamlOpamRoot}}"
              else
                export OPAMROOT="''${OPAMROOT:-$PWD/${oxCamlOpamRoot}}"
              fi
              if [ -d "$OPAMROOT/${oxCamlSwitch}" ]; then
                export OPAMSWITCH="${oxCamlSwitch}"
                eval "$(opam env --switch "${oxCamlSwitch}" --set-switch)"
              fi
              echo "Effet OxCaml research shell"
              echo "Run 'effet-oxcaml-init' once to create the ${oxCamlSwitch} opam switch."
              echo "Run 'effet-oxcaml-test-shipped' after setup to test shipped packages only."
            '';
          };
        }
      );
    };
}
