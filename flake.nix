{
  description = "Eta OCaml development environment";

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
            name = "eta-oxcaml-init";
            runtimeInputs = [
              pkgs.git
              pkgs.opam
              pkgs.python3
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
              opam install \
                'dune=3.22.2+ox' \
                'ocamlformat=0.26.2+ox1' \
                'merlin=5.2.1-502+ox1' \
                'ocaml-lsp-server=1.19.0+ox1' \
                --assume-depexts \
                --yes
              opam install \
                'sqlite3=5.4.1' \
                'caqti=2.3.0' \
                'caqti-driver-sqlite3=2.3.0' \
                'caqti-eio=2.3.0' \
                --assume-depexts \
                --yes

              echo "OxCaml switch is ready: $switch_name"
              echo "Enter it with: nix develop .#oxcaml"
            '';
          };
          oxCamlToolchainCheck = pkgs.writeShellApplication {
            name = "eta-oxcaml-check-toolchain";
            runtimeInputs = [
              pkgs.git
              pkgs.opam
              pkgs.python3
            ];
            text = ''
              repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
              cd "$repo_root"

              export OPAMROOT="''${OPAMROOT:-$repo_root/${oxCamlOpamRoot}}"
              export OPAMSWITCH="${oxCamlSwitch}"
              eval "$(opam env --switch "${oxCamlSwitch}" --set-switch)"

              test "$(ocamlc -version)" = "${oxCamlSwitch}"
              test "$(dune --version)" = "3.22.2"
              opam list --installed --short ocamlformat | grep -Fxq ocamlformat
              opam list --installed --short merlin | grep -Fxq merlin
              opam list --installed --short ocaml-lsp-server | grep -Fxq ocaml-lsp-server

              mode_probe="scratch/oxcaml_research/toolchain_probe/mode_syntax.ml"
              dune build scratch/oxcaml_research/toolchain_probe/mode_syntax.exe
              ocamlformat --enable-outside-detected-project --check "$mode_probe"
              probe_source="$(cat "$mode_probe")"
              printf '%s\n' "$probe_source" \
                | ocamlmerlin single errors -filename "$mode_probe" \
                | python3 scratch/oxcaml_research/toolchain_probe/check_merlin_no_errors.py
              python3 scratch/oxcaml_research/toolchain_probe/check_lsp_no_errors.py "$mode_probe"
            '';
          };
          oxCamlShippedTests = pkgs.writeShellApplication {
            name = "eta-oxcaml-test-shipped";
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
                packages/eta-redacted \
                packages/eta \
                packages/eta-ai \
                packages/eta-ai-anthropic \
                packages/eta-ai-openai-compat \
                packages/eta-ai-openai \
                packages/eta-ai-openrouter \
                packages/eta-otel \
                packages/eta-schema \
                packages/eta-stream \
                packages/ppx_eta \
                packages/eta-redacted/test \
                packages/eta/test \
                packages/eta-ai/test \
                packages/eta-ai-anthropic/test \
                packages/eta-ai-openai-compat/test \
                packages/eta-ai-openai/test \
                packages/eta-ai-openrouter/test \
                packages/eta-otel/test \
                packages/eta-schema/test \
                packages/eta-stream/test \
                packages/ppx_eta/test

              dune runtest \
                packages/eta-redacted \
                packages/eta \
                packages/eta-ai \
                packages/eta-ai-anthropic \
                packages/eta-ai-openai-compat \
                packages/eta-ai-openai \
                packages/eta-ai-openrouter \
                packages/eta-otel \
                packages/eta-schema \
                packages/eta-stream \
                packages/ppx_eta \
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
              pkgs.nghttp2
              pkgs.opam
              pkgs.patch
              pkgs.pkg-config
              pkgs.sqlite
              pkgs.unzip
              pkgs.which
              oxCamlSetup
              oxCamlShippedTests
              oxCamlToolchainCheck
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              pkgs.gmp
              pkgs.caddy
              pkgs.jq
              pkgs.libev
              pkgs.libffi
              pkgs.mkcert
              pkgs.nginx
              pkgs.openssl
              pkgs.zlib
            ];
        in
        {
          default = pkgs.mkShell {
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
              echo "Eta OxCaml shell (${oxCamlSwitch})"
              echo "Run 'eta-oxcaml-init' once to create the ${oxCamlSwitch} opam switch."
              echo "Run 'eta-oxcaml-test-shipped' after setup to test shipped packages only."
            '';
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
              echo "Eta OxCaml research shell (${oxCamlSwitch})"
              echo "Run 'eta-oxcaml-init' once to create the ${oxCamlSwitch} opam switch."
              echo "Run 'eta-oxcaml-test-shipped' after setup to test shipped packages only."
            '';
          };

          # Mainline is retained only for before/after performance comparison.
          # The default development shell is OxCaml.
          mainline = pkgs.mkShell {
            packages = [
              ocamlPackages.ocaml
              ocamlPackages.dune_3
              ocamlPackages.findlib
              ocamlPackages.eio
              ocamlPackages.eio_main
              ocamlPackages.alcotest
              ocamlPackages.cstruct
              ocamlPackages.mirage-crypto
              ocamlPackages.yojson
              ocamlPackages.ppxlib
            ];

            shellHook = ''
              echo "Eta mainline OCaml comparison shell (nixpkgs ocamlPackages.ocaml ${ocamlPackages.ocaml.version})"
              echo "Use this only for benchmark comparison; default development is OxCaml."
            '';
          };
        }
      );
    };
}
