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
          oxCamlOpamRoot = "$HOME/.cache/opam";
          nativePkgConfigPath = pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" (
            [ pkgs.sqlite ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              pkgs.openssl
              pkgs.zlib
            ]
          );
          # nixpkgs' turso package installs only the CLI in this lock; build the
          # SQLite-compatible C ABI that eta_turso loads at runtime.
          tursoSqlite3 = pkgs.rustPlatform.buildRustPackage {
            pname = "turso-sqlite3";
            version = "0.6.0";
            src = pkgs.fetchFromGitHub {
              owner = "tursodatabase";
              repo = "turso";
              tag = "v0.6.0";
              hash = "sha256-uOrvQZ16TlgRFt7kiKIPMT84S07PArVdw6OWzDt7rD8=";
            };
            cargoHash = "sha256-Go+KAU4xz4DO585afx7tKpyWY/Glz6ZAETd0p3uOGiE=";
            cargoBuildFlags = [
              "-p"
              "turso_sqlite3"
            ];
            doCheck = false;
            installPhase = ''
              runHook preInstall
              libname="libturso_sqlite3${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}"
              found="$(find target -path "*/release/$libname" -type f | head -n1)"
              if [ -z "$found" ]; then
                echo "could not find $libname" >&2
                find target -maxdepth 5 -type f -name "libturso_sqlite3*"
                exit 1
              fi
              install -Dm755 "$found" "$out/lib/$libname"
              install -Dm644 sqlite3/include/sqlite3.h "$out/include/sqlite3.h"
              runHook postInstall
            '';
          };
          tursoLibraryPath =
            "${tursoSqlite3}/lib/libturso_sqlite3${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
          ladybugLibraryPath =
            if pkgs.stdenv.isDarwin then
              "${pkgs.ladybugdb.lib}/lib/liblbug.dylib"
            else
              "${pkgs.ladybugdb.lib}/lib/liblbug.so.0.15.3";
          oxCamlSetup = pkgs.writeShellApplication {
            name = "eta-oxcaml-init";
            runtimeInputs = [
              pkgs.autoconf
              pkgs.git
              pkgs.gnumake
              pkgs.m4
              pkgs.opam
              pkgs.patch
              pkgs.pkg-config
              pkgs.python3
              pkgs.sqlite
            ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              pkgs.gmp
              pkgs.libev
              pkgs.libffi
              pkgs.openssl
              pkgs.zlib
            ];
            text = ''
              switch_name="''${1:-${oxCamlSwitch}}"
              repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
              cd "$repo_root"

              export OPAMROOT="''${OPAMROOT:-${oxCamlOpamRoot}}"
              export OPAMYES=1
              export PKG_CONFIG_PATH="${nativePkgConfigPath}:''${PKG_CONFIG_PATH:-}"

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
              opam install 'uring=0.9' --assume-depexts --yes
              opam install . --deps-only --with-test --assume-depexts --yes
              opam install \
                'dune=3.22.2+ox' \
                'ocamlformat=0.26.2+ox1' \
                'merlin=5.2.1-502+ox1' \
                'ocaml-lsp-server=1.19.0+ox1' \
                'utop=2.16.0+ox1' \
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
              pkgs.pkg-config
              pkgs.python3
              pkgs.sqlite
            ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              pkgs.openssl
              pkgs.zlib
            ];
            text = ''
              repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
              cd "$repo_root"

              export OPAMROOT="''${OPAMROOT:-${oxCamlOpamRoot}}"
              export OPAMSWITCH="${oxCamlSwitch}"
              export PKG_CONFIG_PATH="${nativePkgConfigPath}:''${PKG_CONFIG_PATH:-}"
              eval "$(opam env --switch "${oxCamlSwitch}" --set-switch)"

              test "$(ocamlc -version)" = "${oxCamlSwitch}"
              test "$(dune --version)" = "3.22.2"
              opam list --installed --short ocamlformat | grep -Fxq ocamlformat
              opam list --installed --short merlin | grep -Fxq merlin
              opam list --installed --short ocaml-lsp-server | grep -Fxq ocaml-lsp-server
              opam list --installed --short utop | grep -Fxq utop

              mode_probe="tools/oxcaml_toolchain_probe/mode_syntax.ml"
              dune build ./tools/oxcaml_toolchain_probe/mode_syntax.exe
              ocamlformat --enable-outside-detected-project --check "$mode_probe"
              probe_source="$(cat "$mode_probe")"
              printf '%s\n' "$probe_source" \
                | ocamlmerlin single errors -filename "$mode_probe" \
                | python3 tools/oxcaml_toolchain_probe/check_merlin_no_errors.py
              python3 tools/oxcaml_toolchain_probe/check_lsp_no_errors.py "$mode_probe"
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

              export OPAMROOT="''${OPAMROOT:-${oxCamlOpamRoot}}"
              export OPAMSWITCH="$switch_name"
              export PKG_CONFIG_PATH="${nativePkgConfigPath}:''${PKG_CONFIG_PATH:-}"
              export ETA_DUCKDB_LIBRARY="${pkgs.duckdb.lib}/lib/libduckdb.so"
              export ETA_TURSO_LIBRARY="${tursoLibraryPath}"
              export ETA_LADYBUG_LIBRARY="${ladybugLibraryPath}"
              eval "$(opam env --switch "$switch_name" --set-switch)"

              dune build \
                lib/redacted \
                lib/eta \
                lib/ai \
                lib/ai/anthropic \
                lib/ai/openai_compat \
                lib/ai/openai \
                lib/ai/openrouter \
                lib/duckdb \
                lib/otel \
                lib/ladybug \
                lib/schema \
                lib/turso \
                lib/stream \
                lib/ppx \
                test/redacted \
                test/eta \
                test/ai/core \
                test/ai/anthropic \
                test/ai/openai_compat \
                test/ai/openai \
                test/ai/openrouter \
                test/connectors \
                test/otel \
                test/schema \
                test/stream \
                test/ppx

              dune runtest \
                lib/redacted \
                lib/eta \
                lib/ai \
                lib/ai/anthropic \
                lib/ai/openai_compat \
                lib/ai/openai \
                lib/ai/openrouter \
                lib/duckdb \
                lib/otel \
                lib/ladybug \
                lib/schema \
                lib/turso \
                lib/stream \
                lib/ppx \
                test/connectors \
                --force
            '';
          };
          oxCamlHostPackages =
            [
              pkgs.autoconf
              pkgs.cacert
              pkgs.curl
              pkgs.duckdb
              pkgs.git
              pkgs.go
              pkgs.gnumake
              pkgs.ladybugdb.lib
              pkgs.m4
              pkgs.nghttp2
              pkgs.nodejs_24
              pkgs.oha
              pkgs.opam
              pkgs.patch
              pkgs.pkg-config
              pkgs.sqlite
              pkgs.unzip
              pkgs.which
              tursoSqlite3
              oxCamlSetup
              oxCamlShippedTests
              oxCamlToolchainCheck
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              pkgs.gmp
              pkgs.caddy
              pkgs.jq
              pkgs.jdk21_headless
              pkgs.libev
              pkgs.libffi
              pkgs.mkcert
              pkgs.nginx
              pkgs.openssl
              pkgs.scala-cli
              pkgs.zlib
            ];
          mainlineShippedTests = pkgs.writeShellApplication {
            name = "eta-mainline-test-shipped";
            runtimeInputs = [
              pkgs.git
            ];
            text = ''
              repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
              cd "$repo_root"

              export PKG_CONFIG_PATH="${nativePkgConfigPath}:''${PKG_CONFIG_PATH:-}"
              export ETA_DUCKDB_LIBRARY="${pkgs.duckdb.lib}/lib/libduckdb.so"
              export ETA_TURSO_LIBRARY="${tursoLibraryPath}"
              export ETA_LADYBUG_LIBRARY="${ladybugLibraryPath}"

              dune build \
                lib/redacted \
                lib/eta \
                lib/stream \
                lib/http \
                lib/schema \
                lib/schema_test \
                lib/test \
                lib/ppx \
                lib/ai \
                lib/ai/openai_codec \
                lib/ai/anthropic \
                lib/ai/openai_compat \
                lib/ai/openai \
                lib/ai/openrouter \
                lib/otel \
                lib/sql_dsl \
                lib/sql_driver \
                lib/sql \
                lib/duckdb \
                lib/turso \
                lib/ladybug

              dune runtest --force
              dune build @bench
            '';
          };
        in
        {
          default = pkgs.mkShell {
            packages = oxCamlHostPackages;

            shellHook = ''
              export OPAMROOT="''${OPAMROOT:-${oxCamlOpamRoot}}"
              export PKG_CONFIG_PATH="${nativePkgConfigPath}:''${PKG_CONFIG_PATH:-}"
              export ETA_DUCKDB_LIBRARY="${pkgs.duckdb.lib}/lib/libduckdb.so"
              export ETA_TURSO_LIBRARY="${tursoLibraryPath}"
              export ETA_LADYBUG_LIBRARY="${ladybugLibraryPath}"
              if [ -d "$OPAMROOT/${oxCamlSwitch}" ]; then
                export OPAMSWITCH="${oxCamlSwitch}"
                eval "$(opam env --switch "${oxCamlSwitch}" --set-switch)"
              fi
              if [ -t 1 ]; then
                echo "Eta OxCaml shell (${oxCamlSwitch})"
                echo "Run 'eta-oxcaml-init' once to create the ${oxCamlSwitch} opam switch."
                echo "Run 'eta-oxcaml-test-shipped' after setup to test shipped packages only."
              fi
            '';
          };

          oxcaml = pkgs.mkShell {
            packages = oxCamlHostPackages;

            shellHook = ''
              export OPAMROOT="''${OPAMROOT:-${oxCamlOpamRoot}}"
              export PKG_CONFIG_PATH="${nativePkgConfigPath}:''${PKG_CONFIG_PATH:-}"
              export ETA_DUCKDB_LIBRARY="${pkgs.duckdb.lib}/lib/libduckdb.so"
              export ETA_TURSO_LIBRARY="${tursoLibraryPath}"
              export ETA_LADYBUG_LIBRARY="${ladybugLibraryPath}"
              if [ -d "$OPAMROOT/${oxCamlSwitch}" ]; then
                export OPAMSWITCH="${oxCamlSwitch}"
                eval "$(opam env --switch "${oxCamlSwitch}" --set-switch)"
              fi
              if [ -t 1 ]; then
                echo "Eta OxCaml research shell (${oxCamlSwitch})"
                echo "Run 'eta-oxcaml-init' once to create the ${oxCamlSwitch} opam switch."
                echo "Run 'eta-oxcaml-test-shipped' after setup to test shipped packages only."
              fi
            '';
          };

          # Mainline is retained only for before/after performance comparison.
          # It is also the upstream OCaml compatibility gate for this experiment.
          mainline = pkgs.mkShell {
            packages = [
              mainlineShippedTests
              ocamlPackages.ocaml
              ocamlPackages.dune_3
              ocamlPackages.findlib
              ocamlPackages.eio
              ocamlPackages.eio_main
              ocamlPackages.js_of_ocaml
              ocamlPackages.js_of_ocaml-ppx
              ocamlPackages.alcotest
              ocamlPackages.angstrom
              ocamlPackages.base64
              ocamlPackages.bigstringaf
              ocamlPackages.cstruct
              ocamlPackages.crowbar
              ocamlPackages.decompress
              ocamlPackages.domain-name
              ocamlPackages.utop
              ocamlPackages.faraday
              ocamlPackages.h2
              ocamlPackages.hpack
              ocamlPackages.ipaddr
              ocamlPackages.yojson
              ocamlPackages.ppxlib
              pkgs.duckdb
              pkgs.git
              pkgs.ladybugdb.lib
              pkgs.nghttp2
              pkgs.openssl
              pkgs.pkg-config
              pkgs.sqlite
              tursoSqlite3
            ];

            shellHook = ''
              export PKG_CONFIG_PATH="${nativePkgConfigPath}:''${PKG_CONFIG_PATH:-}"
              export ETA_DUCKDB_LIBRARY="${pkgs.duckdb.lib}/lib/libduckdb.so"
              export ETA_TURSO_LIBRARY="${tursoLibraryPath}"
              export ETA_LADYBUG_LIBRARY="${ladybugLibraryPath}"
              echo "Eta mainline OCaml comparison shell (nixpkgs ocamlPackages.ocaml ${ocamlPackages.ocaml.version})"
              echo "Use this for upstream OCaml compatibility work and benchmark comparison."
            '';
          };
        }
      );
    };
}
