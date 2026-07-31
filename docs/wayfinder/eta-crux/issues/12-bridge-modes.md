# Bridge modes, including foreign-language in-process

Type: grilling
Status: open

## Question

The boundary currently has two modes: serialization when crossing a process or language
boundary, and direct typed values in-process. Crux mirrors the same split, with a serialized
bridge for UniFFI and Wasm, or direct import for Rust shells. Neither covers the case of
**same-process, foreign-language, generated typed contracts, no serialization** — which is
js_of_ocaml against TypeScript, and equally OCaml against C++ through ctypes or an
FFI-generated Slint binding.

Hosts already generate typed contracts in both directions with no serialization, so
requiring a wire format would add encoding to the hot path of a boundary that is type-checked
end to end. Getting this wrong pushes every FFI adapter into either unsafe dynamic casts or
needless serialization.

Decide:

- Whether three bridge modes are defined: same-language in-process, foreign-language
  in-process with generated typed contracts, and cross-process.
- That the foreign-language in-process mode requires generated typed contracts for actions,
  fragments and capability messages, and requires no serialization.
- That serialization is required only in the cross-process mode, and only for those payload
  types.
