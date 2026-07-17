{
  description = "Eta OCaml development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.opam-nix = {
    url = "github:tweag/opam-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  inputs.opam-repository = {
    url = "github:ocaml/opam-repository";
    flake = false;
  };
  inputs.oxcaml = {
    url = "github:oxcaml/oxcaml/5.2.0minus-31";
    flake = false;
  };

  outputs =
    {
      nixpkgs,
      opam-nix,
      opam-repository,
      oxcaml,
      ...
    }:
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
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          cleanLocalSource =
            src:
            pkgs.lib.cleanSourceWith {
              inherit src;
              filter =
                path: _type:
                let
                  base = baseNameOf path;
                in
                !(
                  base == ".git"
                  || base == "_build"
                  || base == "_opam"
                  || base == ".opam"
                  || base == ".opam-oxcaml"
                  || base == ".reference"
                  || base == ".scratch"
                  || base == ".motel-data"
                  || base == ".nema"
                  || base == ".pi"
                  || base == ".hill-climbing"
                  || base == "node_modules"
                );
          };
          etaSrc = cleanLocalSource ./.;
          patchedOxcaml = pkgs.runCommand "oxcaml-source-patched" { } ''
            cp -R ${oxcaml} "$out"
            chmod -R u+w "$out"
            ${pkgs.perl}/bin/perl -0pi -e 's|new: old: \{\n        buildInputs = \[|new: old: rec {\n        version = "20231231";\n        src = pkgs.fetchFromGitLab {\n          domain = "gitlab.inria.fr";\n          owner = "fpottier";\n          repo = "menhir";\n          rev = version;\n          sha256 = "sha256-veB0ORHp6jdRwCyDDAfc7a7ov8sOeHUmiELdOFf/QYk=";\n        };\n        patches = [ ];\n        buildInputs = [|' "$out/default.nix"
          '';
          oxcamlCompiler = pkgs.callPackage "${patchedOxcaml}/default.nix" {
            src = patchedOxcaml;
            ocamltest = false;
            warnError = false;
          };
          oxcamlSystemOverlay = final: prev: {
            ocaml-system = prev.ocaml-system.overrideAttrs (_old: {
              nativeBuildInputs = [ oxcamlCompiler ];
            });
          };
          buildOpamProjectPrime = builtins.getAttr "buildOpamProject'" opam-nix.lib.${system};
          etaScope = buildOpamProjectPrime
            {
              inherit pkgs;
              overlays = [ oxcamlSystemOverlay ];
              repos = [ opam-repository ];
              resolveArgs.env.sys-ocaml-version = "5.2.0";
            }
            etaSrc
            {
              ocaml-system = "*";
            };
          etaPackageNames = [
            "eta"
            "eta_ai"
            "eta_ai_openai_codec"
            "eta_ai_openrouter"
            "eta_exa"
            "eta_blocking"
            "eta_eio"
            "eta_http"
            "eta_http_eio"
            "eta_http_h1"
            "eta_http_h2"
            "eta_http_service"
            "eta_http_service_eio"
            "eta_http_tls_openssl"
            "eta_http_ws"
            "eta_ladybug"
            "eta_linux_input"
            "eta_otel"
            "eta_redacted"
            "eta_router"
            "eta_signal"
            "eta_sql"
            "eta_sql_driver"
            "eta_sql_dsl"
            "eta_stream"
          ];
          etaPackages = builtins.listToAttrs (
            map (name: {
              inherit name;
              value = etaScope.${name};
            }) etaPackageNames
          );
        in
        etaPackages // {
          default = etaPackages.eta;
        }
      );

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
          ladybugdb = pkgs.ladybugdb.overrideAttrs (finalAttrs: _previousAttrs: {
            version = "0.17.1";
            src = pkgs.fetchFromGitHub {
              owner = "LadybugDB";
              repo = "ladybug";
              tag = "v${finalAttrs.version}";
              hash = "sha256-3d0gsSLkO5Np6P4l8AEfEPvzMlkf2wYMCluAtDrwEDc=";
            };
          });
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
            "${ladybugdb.lib}/lib/liblbug${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
          etaOpamInstall = pkgs.writeShellApplication {
            name = "eta-opam-install";
            runtimeInputs = [
              pkgs.autoconf
              pkgs.coreutils
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
              switch_name="''${ETA_OPAM_SWITCH:-${oxCamlSwitch}}"
              repo_root="''${ETA_REPO_ROOT:-/home/ribelo/projects/ribelo/ocaml/Eta}"
              cd "$repo_root"

              export OPAMROOT="''${OPAMROOT:-${oxCamlOpamRoot}}"
              export OPAMYES=1
              export PKG_CONFIG_PATH="${nativePkgConfigPath}:''${PKG_CONFIG_PATH:-}"

              if ! opam switch list --short | grep -Fxq "$switch_name"; then
                echo "Missing OPAM switch '$switch_name'." >&2
                echo "Run: shared-ocaml-switch-init" >&2
                exit 1
              fi

              export OPAMSWITCH="$switch_name"
              eval "$(opam env --switch "$switch_name" --set-switch)"

              eta_url="git+file://$repo_root#master"
              packages="''${ETA_OPAM_PACKAGES:-eta eta_ai eta_ai_openai_codec eta_ai_openrouter eta_blocking eta_eio eta_exa eta_http eta_http_eio eta_http_h1 eta_http_h2 eta_http_service eta_http_service_eio eta_http_tls_openssl eta_http_ws eta_ladybug eta_linux_input eta_otel eta_redacted eta_router eta_signal eta_sql eta_sql_driver eta_sql_dsl eta_stream}"
              if [ "$#" -gt 0 ]; then
                packages="$*"
              fi

              package_args=()
              for package in $packages; do
                package_args+=("$package")
                opam pin add --kind=git "$package" "$eta_url" --no-action --yes
              done

              opam install "''${package_args[@]}" --assume-depexts --yes

              echo "Eta packages installed into OPAM switch: $switch_name"
              echo "$packages"
            '';
          };
          etaOpamInstallOx = pkgs.writeShellApplication {
            name = "eta-opam-install-ox";
            runtimeInputs = [ etaOpamInstall ];
            text = ''
              export ETA_OPAM_SWITCH="${oxCamlSwitch}"
              exec eta-opam-install "$@"
            '';
          };
          etaOpamInstallMainline = pkgs.writeShellApplication {
            name = "eta-opam-install-mainline";
            runtimeInputs = [ etaOpamInstall ];
            text = ''
              export ETA_OPAM_SWITCH="5.4.1"
              export ETA_OPAM_PACKAGES="eta eta_http eta_jsoo eta_http_js"
              exec eta-opam-install "$@"
            '';
          };
          oxCamlSetup = pkgs.writeShellApplication {
            name = "eta-oxcaml-init";
            runtimeInputs = [
              etaOpamInstall
            ];
            text = ''
              if [ "$#" -gt 0 ]; then
                export ETA_OPAM_SWITCH="$1"
                shift
              fi
              exec eta-opam-install "$@"
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
                drivers/eta_duckdb \
                lib/otel \
                drivers/eta_ladybug \
                lib/schema \
                lib/schema_test \
                drivers/eta_turso \
                lib/stream \
                lib/ppx \
                test/redacted_eio \
                test/eta \
                test/ai/core \
                test/ai/anthropic \
                test/ai/openai_compat \
                test/ai/openai \
                test/ai/openrouter \
                test/connectors \
                test/otel \
                test/schema_eio \
                test/schema_test_eio \
                test/stream \
                test/ppx_eio

              dune runtest \
                lib/redacted \
                lib/eta \
                lib/ai \
                lib/ai/anthropic \
                lib/ai/openai_compat \
                lib/ai/openai \
                lib/ai/openrouter \
                drivers/eta_duckdb \
                lib/otel \
                drivers/eta_ladybug \
                lib/schema \
                lib/schema_test \
                drivers/eta_turso \
                lib/stream \
                lib/ppx \
                test/schema_eio \
                test/schema_test_eio \
                test/ppx_eio \
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
              pkgs.h2spec
              ladybugdb.lib
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
              etaOpamInstall
              etaOpamInstallOx
              etaOpamInstallMainline
              oxCamlSetup
              oxCamlShippedTests
              oxCamlToolchainCheck
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              pkgs.gmp
              pkgs.caddy
              pkgs.gdb
              pkgs.jq
              pkgs.jdk21_headless
              pkgs.libev
              pkgs.libffi
              pkgs.mkcert
              pkgs.nginx
              pkgs.openssl
              pkgs.scala-cli
              pkgs.valgrind
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
                drivers/eta_duckdb \
                drivers/eta_turso \
                drivers/eta_ladybug

              dune runtest --force
              dune build @bench
            '';
          };
          ocaml54ShippedTests = pkgs.writeShellApplication {
            name = "eta-ocaml54-test-erg";
            runtimeInputs = [
              pkgs.git
            ];
            text = ''
              repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
              cd "$repo_root"

              export PKG_CONFIG_PATH="${nativePkgConfigPath}:''${PKG_CONFIG_PATH:-}"

              dune build \
                lib/redacted \
                lib/eta \
                lib/blocking \
                lib/eio \
                lib/exa \
                lib/stream \
                lib/http \
                lib/http/h1 \
                lib/http/h2 \
                lib/http/ws \
                lib/http_tls_openssl \
                lib/http_eio \
                lib/schema \
                lib/schema_test \
                lib/test \
                lib/ai \
                lib/ai/openai_codec \
                lib/ai/openrouter

              dune runtest --force \
                test/eta \
                test/exa \
                test/redacted_common \
                test/redacted_eio \
                test/stream \
                test/stream_common \
                test/stream_eio \
                test/http_common \
                test/http \
                test/http/tls \
                test/http_eio \
                test/schema_common \
                test/schema_eio \
                test/schema_test_common \
                test/schema_test_eio \
                test/ai_common \
                test/ai_eio \
                test/ai/core \
                test/ai/openrouter
            '';
          };
          ocaml54HostPackages = [
            ocaml54ShippedTests
            ocamlPackages.ocaml
            ocamlPackages.dune_3
            ocamlPackages.findlib
            ocamlPackages.eio
            ocamlPackages.eio_main
            ocamlPackages.alcotest
            ocamlPackages.angstrom
            ocamlPackages.base64
            ocamlPackages.bigstringaf
            ocamlPackages.cstruct
            ocamlPackages.crowbar
            ocamlPackages.decompress
            ocamlPackages.domain-name
            ocamlPackages.faraday
            ocamlPackages.ipaddr
            ocamlPackages.yojson
            pkgs.git
            pkgs.openssl
            pkgs.pkg-config
          ];
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
                echo "Run 'shared-ocaml-switch-init' to create shared OPAM switches."
                echo "Run 'eta-opam-install' to install Eta packages into ${oxCamlSwitch}."
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
                echo "Run 'shared-ocaml-switch-init' to create shared OPAM switches."
                echo "Run 'eta-opam-install' to install Eta packages into ${oxCamlSwitch}."
                echo "Run 'eta-oxcaml-test-shipped' after setup to test shipped packages only."
              fi
            '';
          };

          ocaml54 =
            assert ocamlPackages.ocaml.version == "5.4.1";
            pkgs.mkShell {
              packages = ocaml54HostPackages;

              shellHook = ''
                export PKG_CONFIG_PATH="${nativePkgConfigPath}:''${PKG_CONFIG_PATH:-}"
                echo "Eta Erg native shell (upstream OCaml ${ocamlPackages.ocaml.version})"
                echo "Run 'eta-ocaml54-test-erg' for the Erg dependency gate."
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
              ocamlPackages.ipaddr
              ocamlPackages.yojson
              ocamlPackages.ppxlib
              pkgs.duckdb
              pkgs.git
              ladybugdb.lib
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
