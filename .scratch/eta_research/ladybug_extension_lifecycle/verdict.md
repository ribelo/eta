# Verdict

Implemented path: Eta_ladybug.Extension plus Connection and Pool helpers.

Source evidence from LadybugDB v0.15.3:

- Grammar: scripts/antlr4/Cypher.g4 defines LOAD, LOAD EXTENSION, INSTALL,
  FORCE INSTALL, UNINSTALL, and UPDATE.
- Binder: src/binder/bind/bind_extension.cpp validates official extensions
  separately from local filesystem paths.
- Runtime: src/extension/extension_manager.cpp loads dynamic libraries and
  records loaded extensions; src/extension/extension_installer.cpp downloads
  official extension artifacts into home_directory/.lbdb/extension.
- Listing: SHOW_LOADED_EXTENSIONS and SHOW_OFFICIAL_EXTENSIONS are table
  functions with typed columns.

Runtime evidence:

- LOAD EXTENSION '/tmp/.../libeta_test.lbug_extension' loaded a minimal real
  dynamic extension exporting name and init; SHOW_LOADED_EXTENSIONS reported
  ETA_TEST, USER, and the extension path.
- INSTALL JSON with a temporary home_directory downloaded libjson.lbug_extension;
  LOAD EXTENSION JSON loaded it; SHOW_LOADED_EXTENSIONS reported JSON,
  OFFICIAL, and the installed extension path.
- In Eta, official extension loading initially failed while local no-op loading
  succeeded. The cause was Eta's Ladybug loader using RTLD_LOCAL for liblbug;
  official extensions need liblbug symbols to be globally visible, so the
  connector now opens liblbug with RTLD_GLOBAL.
- LOAD EXTENSION JSON before install fails with LadybugDB's binder error.
- LOAD EXTENSION '/tmp/does-not-exist.lbug_extension' fails with LadybugDB's
  binder error.

Default Eta tests cover the deterministic local extension lifecycle. The
official remote install lifecycle is present as an opt-in test guarded by
ETA_LADYBUG_TEST_REMOTE_EXTENSIONS=1, because the upstream extension server is
network state and should not make the default test suite flaky.
