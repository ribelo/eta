# Candidates

## A. Keep Connection.exec only

Rejected. It is technically possible, but callers must manually quote local
paths and repository URLs, cannot reuse typed listing decoders, and would repeat
the same install/load error handling.

## B. Add only load_extension_path

Rejected. Local user extensions are real and deterministic, but LadybugDB also
has official INSTALL, LOAD EXTENSION, UPDATE, and UNINSTALL statements. Exposing
only the local path helper would leave the official lifecycle half raw.

## C. Add explicit extension helpers over LadybugDB statements

Accepted. The helper surface maps directly to stable LadybugDB statements:
INSTALL, FORCE INSTALL, UPDATE, UNINSTALL, LOAD EXTENSION for official names,
LOAD EXTENSION for local paths, SHOW_LOADED_EXTENSIONS, and
SHOW_OFFICIAL_EXTENSIONS.

## D. Add C stubs for extension lifecycle

Rejected. The installed lbug.h exposes query, prepare, and execute APIs, but no
extension-specific C functions. Adding stubs would be fake surface area.
