# Native loading and HMR

Date: 2026-08-14

## Decision

Eta can support native hot module replacement (HMR) as declaration
replacement. Eta cannot support machine-code replacement or code unloading in
one process.

The native adapter must load each candidate as a new, private `.cmxs` file.
Each artifact must have an immutable generation path and a unique compilation
unit. The plugin must register one component declaration through a stable host
interface. Code loading only makes that declaration available.

The reconciler must replace the active declaration in a separate operation.
It must close the old component context before it installs the candidate. If
installation fails, it must close the candidate context and install the old
declaration as a new component instance.

This contract does not preserve component-local state. It also does not remove
any loaded machine code. A process restart is the only complete code-reclamation
operation.

## Scope and terms

This report uses five different operations:

1. **Load new code.** `Dynlink` maps a new `.cmxs` file and runs its module
   initializers.
2. **Replace a declaration.** The reconciler changes the declaration selected
   for one component identity.
3. **Withdraw effects.** The runtime closes the old component context and its
   owned registrations, children, and acquisitions.
4. **Restore the old declaration.** The runtime installs the retained old
   declaration as a fresh instance.
5. **Unload machine code.** The platform removes executable pages and runtime
   metadata for a plugin.

Only the first four operations are feasible. The fifth operation is not part
of the `Dynlink` contract.[O1][O2]

The portable semantic contract starts at operation 2. File watching,
compilation, artifact storage, and `Dynlink` belong to a native adapter.

## Repository target

The repository pins the OxCaml input
`oxcaml/oxcaml/5.2.0minus-31` at commit
`7d714cfb3f1c79c9b1e2a9c40ac60ba0c44cafd7`.[E1] The Nix shell reported these
values:

| Item | Value |
| --- | --- |
| `ocamlc -version` | `5.2.0+ox` |
| `ocamlopt -version` | `5.2.0+ox` |
| `dune --version` | `3.22.2` |
| Host and target | `x86_64-pc-linux-gnu` |
| Architecture and system | `amd64`, `linux` |
| `supports_shared_libraries` | `true` |
| `native_dynlink` | `true` |
| Flambda | `false` |
| Flambda 2 | `true` |
| Plugin magic | `Caml1999D573` |

The repository declares Dune language version 3.21. The package declarations
require Dune 3.21 or later.[E2]

These results establish native loading only for the repository Linux AMD64
environment. The flake lists Linux and Darwin on AMD64 and ARM64, but this
research did not run the other three systems.[E1]

## Loader facts

### Native artifacts

`Dynlink.loadfile` loads `.cmxs` files in a native program. It loads `.cmo` or
`.cma` files in a bytecode program. `Dynlink.adapt_filename` selects `.cmxs`
for native code.[O1]

Native and bytecode objects cannot be mixed. The native target therefore
cannot use a bytecode plugin as a fallback.[O3]

`ocamlopt -shared` creates a native plugin. Native plugins exist only on
supported operating systems. On Linux AMD64, OCaml code must not use
`-nodynlink`, and extra native objects must contain position-independent
code.[O3]

Dune creates a `.cmxs` target for each library. Dune also documents an
explicit rule that runs `ocamlopt -shared` for an ad hoc plugin.[D1]

### Entry-point registration

`Dynlink` does not return a module or a named value. It runs all top-level
expressions in the loaded units. A plugin must register its entry points in a
host-owned table.[O1]

The component declaration type must therefore live in a statically linked,
stable host library. The plugin initializer submits a declaration value to
that host library. The loader then reads the staged value by generation ID.

The registry operation must reject these results:

- no submitted declaration,
- more than one submitted declaration,
- a declaration with the wrong component identity,
- a declaration for a different generation.

This protocol gives the host a typed declaration value. It does not make
arbitrary plugin initialization safe.

### Type and implementation identity

`Dynlink` compares the compiled-interface digests used by the host and plugin.
Native loading also compares implementation digests when cross-module
optimization records an implementation dependency.[O2]

The native adapter must compile the host and plugin against the same stable
host `.cmi` files. It must also use the exact repository compiler, target, and
runtime configuration.

The plugin boundary must hide host `.cmx` files or compile that boundary with
`-opaque`. This prevents the plugin from depending on host implementation
details. The OCaml manual recommends hiding `.cmx` files for this purpose.
The `-opaque` option removes cross-module optimization information.[O2][O3]

This is compilation identity, not a permanent binary interface. A host rebuild
that changes the stable interface digest requires new plugins. A compiler or
target change requires a process restart and a complete rebuild.

OxCaml modes and layouts can occur in the stable interface. The compiler
enforces them only when both sides use the same pinned OxCaml toolchain.
This research found no separate OxCaml plugin ABI.

### Public and private loading

`loadfile` makes loaded units available to later plugins. It rejects names that
clash with the main program or an earlier public plugin.[O1]

`loadfile_private` hides loaded units from later plugins. It still rejects a
unit that implements an interface already required by the main program or a
public plugin.[O1]

The native adapter must use `loadfile_private`. It must also call
`Dynlink.allow_only` with an explicit unit list. The list contains the stable
plugin interface and its required standard library units.[O1]

This restriction reduces accidental links to host internals. It is not a
security boundary. Native plugins can contain external functions, and
`allow_unsafe_modules` does nothing in native programs.[O1]


### Unique generations

The pinned OxCaml interface forbids loading the same `.cmxs` file more than
once in private mode.[X1] The Linux loader also returns the same handle when
the process opens the same shared object again.[L1]

Each successful build must produce these new identities:

- a unique artifact path,
- a unique plugin library name,
- a unique top-level compilation unit,
- a monotonic or collision-resistant generation ID.

The unique compilation unit also gives its generated OCaml symbols new names.
This rule avoids reliance on platform symbol selection between generations.

The adapter must never overwrite a loaded artifact. It must copy or rename a
completed build to an immutable generation path before it calls `Dynlink`.

A content hash can identify source equivalence, but it is not sufficient as
the only generation ID. A failed load can leave the same path resident. The
next attempt must use a new path and a new unit.

### Initialization and failure

The pinned loader performs these actions in order:

1. It opens the shared object.
2. It reads and compares the plugin header.
3. It compares imports, implementations, names, and symbols.
4. It registers GC roots, frame tables, and code fragments.
5. It runs each compilation-unit initializer.[X2][X3]

The loader serializes its global state with a mutex on runtime 5. It releases
that mutex while an initializer runs because an initializer can call
`Dynlink`.[X2]

An import, format, or open error occurs before component replacement. The
current declaration and component instance can remain active.

An initializer can mutate host state before a later initializer raises an
exception. `Dynlink` reports `Library's_module_initializers_failed`, but it
does not reverse those mutations.[O1][X2]

The pinned native runtime contains no `dlclose` call in this path. Its open
function has a `TODO` for close-on-error. The native `finish` operation does
nothing.[X2][X3]

As a result, “load failed” does not imply “the process is unchanged.” The
plugin contract must forbid component effects during module initialization.
The host cannot enforce that rule against trusted native code.

## Strongest feasible contract

### File watching, recompilation, and cache invalidation

The native adapter can use Dune as a separate build process. Dune watch mode
rebuilds after file changes. Its RPC server can also accept explicit build
requests.[D2][D3]

The runtime must treat a watch event only as a dirty signal. Linux `inotify`
can coalesce events, lose events after queue overflow, and miss files during
recursive watch races.[L2]

After a dirty signal, the adapter must rescan authoritative inputs. It must
derive the build result from Dune, not from the event sequence.

The adapter must load an artifact only after a successful build and an atomic
move to its immutable path. It must record:

- the artifact digest,
- the generation ID,
- the compiler version,
- the target,
- the plugin magic,
- the stable-interface digest,
- the component identity.

Dune provides incremental build state, but Eta has no managed module cache.
Eta must not infer runtime freshness from a reusable Dune output path.

### Loading

The adapter must serialize load requests. For each request, it performs these
actions:

1. Compare the manifest with the running host.
2. Create an empty staging slot for the generation.
3. Call `Dynlink.loadfile_private` with the immutable artifact path.
4. Require exactly one staged declaration.
5. Return the declaration as an inactive candidate.

If steps 1 through 4 fail, the adapter rejects the candidate. The active
declaration and active instance remain unchanged.

The adapter can clear its staging slot after a failure. It cannot reverse
other initializer effects. It also cannot assume that the plugin code left
the process.

### Configuration reconciliation and replacement

The desired-state tree must identify a declaration generation and a
configuration snapshot. The reconciler must process that pair as one
transaction.

The replacement operation performs these actions:

1. Retain the old declaration and the last committed configuration.
2. Mark the component as replacing.
3. Close the old component context.
4. Install the candidate in a fresh context with the proposed configuration.
5. Commit the candidate generation and configuration after successful
   installation.

Step 3 withdraws all reversible effects that the component context owns.
There can be a period with no active provisions. The contract cannot promise
zero downtime.

If step 4 fails, the reconciler performs these actions:

1. Close the partial candidate context.
2. Install the retained old declaration in a new context.
3. Use the last committed configuration.
4. Report the candidate failure and the restoration result separately.

Restoration is a new installation. Component-local state does not survive.
Longer-lived context or coeffect state can survive only under its separate
ownership contract.

If restoration also fails, the component remains failed and has no active
declaration instance. The runtime must not report the old generation as
active.

The runtime cannot retract irreversible external emissions from either
installation. It can only close resources and registrations that its contexts
own.

### Code retention

The declaration registry can remove obsolete declaration values. Garbage
collection can then remove ordinary heap values that no live object
references.

This removal does not unload plugin code. Closures, return addresses, frame
tables, global roots, and code-fragment metadata can still refer to the
plugin.[X3]

Linux `dlclose` only decrements a platform reference count. Even a successful
call does not guarantee removal from the address space.[L1] Apple documents
similar reference-count behavior and additional non-unloading cases.[A1]
Windows also unmaps a DLL only after its reference count reaches zero.[W1]

Those platform operations do not solve the OCaml runtime references. Eta must
never call them behind `Dynlink`.

The native adapter must expose code retention in diagnostics. A deployment can
set a generation or memory threshold that requests a controlled process
restart. The restart policy belongs above the portable replacement contract.

## Impossible or unsafe Cordis behaviors

The native target cannot safely provide these behaviors:

| Behavior | Result |
| --- | --- |
| Replace a compilation unit under its old public name | `Dynlink` rejects public name clashes. Private reuse also has loader and symbol risks.[O1][X1] |
| Remove old machine code after replacement | `Dynlink` has no unload operation, and the runtime retains code metadata.[O1][X3] |
| Bound native memory across unlimited replacements | Every generation can remain mapped. A process restart is required. |
| Preserve component-local state automatically | The destination excludes state migration. Restoration creates a fresh instance. |
| Roll back arbitrary module initializers | Initializers can perform effects before failure. The host cannot reverse them.[O1][X2] |
| Treat `allow_only` as a sandbox | Native external functions remain allowed.[O1] |
| Load untrusted native plugins | A native plugin executes in the host process with host privileges. |
| Promise atomic, zero-gap replacement | Exclusive resources can require old-instance closure before candidate installation. |
| Retract irreversible external effects | Context closure only withdraws runtime-owned reversible effects. |
| Retry a rebuilt plugin at the same path | OxCaml forbids the same private file twice, and the platform can reuse the old mapping.[X1][L1] |
| Accept plugins from another compiler or interface build | Header, interface, or implementation comparisons can reject them. ABI safety is not available.[O2][X2] |
| Use bytecode as a native fallback | OCaml cannot mix native and bytecode objects.[O3] |
| Infer source truth from file events | Native watch queues can coalesce or lose events.[L2] |

Code loading and declaration replacement must remain separate. This separation
keeps build or load failure away from the active component. It also makes code
retention explicit.

## Minimum portable interface

The portable component package needs no `Dynlink` dependency. Its HMR-facing
seam needs operations equivalent to these concepts:

```text
candidate = load_generation(artifact)
result = reconcile_replace(component_id, candidate, configuration_snapshot)
```

`load_generation` belongs to an optional native loader package.
`reconcile_replace` belongs to the configuration and replacement package.

The candidate is an opaque component declaration plus generation metadata. The
portable runtime does not know whether the declaration came from `Dynlink`, a
static registry, or another source.

The minimum observable states are:

- building,
- load rejected,
- candidate ready,
- withdrawing old effects,
- installing candidate,
- candidate active,
- restoring old declaration,
- old declaration restored,
- component failed.

Diagnostics must keep load errors, installation errors, and restoration errors
distinct. They must also report the count of loaded native generations.

## Platform gaps

The following gaps remain:

- Native loading was not run on `aarch64-linux`, `x86_64-darwin`, or
  `aarch64-darwin`.
- The available compiler configuration does not establish native plugin
  support for every platform in the flake.
- Dune watch mode depends on `inotifywait` or `fswatch`.[D2] Eta still needs
  one selected watch adapter for each supported platform.
- Linux watch overflow recovery needs a full rescan.[L2] Equivalent failure
  behavior needs a platform-specific test on Darwin.
- Windows is not a repository flake target. Windows loader facts do not imply
  OxCaml native-plugin support.
- The pinned OxCaml branch can diverge from upstream OCaml loader fixes.
  Upgrades need a new source review and native probe.

No compiler probe was necessary for loader semantics. The pinned OxCaml
interface and implementation settle the relevant behavior. The Nix command
only established the active versions and platform features.

## Sources

All sources were accessed on 2026-08-14.

- **[E1]** Eta, [`flake.nix`](../../../flake.nix) and
  [`flake.lock`](../../../flake.lock), OxCaml input and supported systems.
- **[E2]** Eta, [`dune-project`](../../../dune-project), Dune language and
  package constraints.
- **[O1]** OCaml 5.2 manual,
  [`Dynlink` API](https://ocaml.org/manual/5.2/api/Dynlink.html).
- **[O2]** OCaml 5.2 manual,
  [The `dynlink` library](https://ocaml.org/manual/5.2/libdynlink.html).
- **[O3]** OCaml 5.2 manual,
  [Native-code compilation](https://ocaml.org/manual/5.2/native.html).
- **[X1]** OxCaml commit `7d714cf`,
  [`otherlibs/dynlink/dynlink.mli`](https://github.com/oxcaml/oxcaml/blob/7d714cfb3f1c79c9b1e2a9c40ac60ba0c44cafd7/otherlibs/dynlink/dynlink.mli).
- **[X2]** OxCaml commit `7d714cf`,
  [`otherlibs/dynlink/dynlink_common.ml`](https://github.com/oxcaml/oxcaml/blob/7d714cfb3f1c79c9b1e2a9c40ac60ba0c44cafd7/otherlibs/dynlink/dynlink_common.ml)
  and
  [`otherlibs/dynlink/native/dynlink.ml`](https://github.com/oxcaml/oxcaml/blob/7d714cfb3f1c79c9b1e2a9c40ac60ba0c44cafd7/otherlibs/dynlink/native/dynlink.ml).
- **[X3]** OxCaml commit `7d714cf`,
  [`runtime/dynlink_nat.c`](https://github.com/oxcaml/oxcaml/blob/7d714cfb3f1c79c9b1e2a9c40ac60ba0c44cafd7/runtime/dynlink_nat.c).
- **[D1]** Dune,
  [Building an ad hoc `.cmxs`](https://dune.readthedocs.io/en/stable/advanced/custom-cmxs.html).
- **[D2]** Dune,
  [Watch mode](https://dune.readthedocs.io/en/stable/usage.html#watch-mode).
- **[D3]** Dune,
  [RPC](https://dune.readthedocs.io/en/stable/rpc.html).
- **[L1]** Linux man-pages,
  [`dlopen(3)` and `dlclose(3)`](https://man7.org/linux/man-pages/man3/dlopen.3.html).
- **[L2]** Linux man-pages,
  [`inotify(7)`](https://man7.org/linux/man-pages/man7/inotify.7.html).
- **[A1]** Apple,
  [`dlclose(3)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/dlclose.3.html).
- **[W1]** Microsoft,
  [Run-time dynamic linking](https://learn.microsoft.com/en-us/windows/win32/dlls/run-time-dynamic-linking).

## Commands

```sh
env XDG_CACHE_HOME=/tmp/eta-nix-cache nix develop -c bash -lc \
  'ocamlc -version && ocamlopt -version && dune --version && ocamlc -config'
uname -a
date -u +%F
git diff --check
```
