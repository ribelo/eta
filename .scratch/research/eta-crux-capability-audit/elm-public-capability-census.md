# Elm public capability census

## Scope and method

This report inventories public architectural capability families, not every public function.
It covers Elm programs and the primary tools that can test complete Elm programs.

### First-party source boundary

The first-party boundary starts with all non-archived public repositories in the
[`elm` GitHub organization](https://github.com/orgs/elm/repositories).
The census includes a repository when it meets one of these conditions:

- It has a public Elm package for programs, host boundaries, UI, data boundaries, or Elm tooling.
- It implements the official compiler or package tools.

This rule includes 16 package repositories and the compiler repository.
It does not include the full community package registry.
The registry contains third-party packages that the `elm` organization does not own.

The 16 first-party package repositories are `browser`, `bytes`, `color`, `core`, `file`,
`html`, `http`, `json`, `parser`, `project-metadata-utils`, `random`, `regex`, `svg`,
`time`, `url`, and `virtual-dom`.
The `color` repository has a package manifest, but the public registry does not list a release.
This report uses its pinned repository state only to record its disposition.

The test boundary adds `elm-explorations/test` and `avh4/elm-program-test`.
These repositories are primary sources for their own public test contracts.
The official guide supplies first-party prose for compiler-defined flags and ports.

The census uses these immutable source snapshots:

- [`elm/core` 1.0.5 at `84f38891468e8e153fc85a9b63bdafd81b24664e`](https://github.com/elm/core/tree/84f38891468e8e153fc85a9b63bdafd81b24664e).
- [`elm/browser` 1.0.2 at `53e3caa265fd9da3ec9880d47bb95eed6fe24ee6`](https://github.com/elm/browser/tree/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6).
- [`elm/time` 1.0.0 at `7b97ef513b289d7b88704fcfc5a0807f7eb4f5ce`](https://github.com/elm/time/tree/7b97ef513b289d7b88704fcfc5a0807f7eb4f5ce).
- [`elm/random` 1.0.0 at `c1c9da4d861363cee1c93382d2687880279ed0dd`](https://github.com/elm/random/tree/c1c9da4d861363cee1c93382d2687880279ed0dd).
- [`elm/http` 2.0.0 at `34a9a27411c2492d3e247ac75cd48e22b473bef5`](https://github.com/elm/http/tree/34a9a27411c2492d3e247ac75cd48e22b473bef5).
- [`elm/file` 1.0.5 at `e4ca3864c93a5e766e24ed6916174753567b2f59`](https://github.com/elm/file/tree/e4ca3864c93a5e766e24ed6916174753567b2f59).
- [`elm/bytes` 1.0.8 at `2bce2aeda4ef18c3dcccd84084647d22a7af36a6`](https://github.com/elm/bytes/tree/2bce2aeda4ef18c3dcccd84084647d22a7af36a6).
- [`elm/html` 1.0.1 at `1affbf39efef4b4529110a567f706130c178a457`](https://github.com/elm/html/tree/1affbf39efef4b4529110a567f706130c178a457).
- [`elm/svg` 1.0.1 at `dfe97e8282f283f4a62b6645f633076cfd24f3f7`](https://github.com/elm/svg/tree/dfe97e8282f283f4a62b6645f633076cfd24f3f7).
- [`elm/virtual-dom` 1.0.5 at `79d31f5889930aa5d0d8e874a0807076d5c16891`](https://github.com/elm/virtual-dom/tree/79d31f5889930aa5d0d8e874a0807076d5c16891).
- [`elm/url` 1.0.0 at `384b1dcf84065a500a71402ec367f3982b35093d`](https://github.com/elm/url/tree/384b1dcf84065a500a71402ec367f3982b35093d).
- [`elm/json` 1.1.4 at `2865dfce97a75724a75583a214d3a287d2abecd4`](https://github.com/elm/json/tree/2865dfce97a75724a75583a214d3a287d2abecd4).
- [`elm/parser` 1.1.0 at `02839df10e462d8423c91917271f4b6f8d2f284d`](https://github.com/elm/parser/tree/02839df10e462d8423c91917271f4b6f8d2f284d).
- [`elm/regex` 1.0.0 at `a6d1b3e93b91a02bf4416c4ba314443b8bc3bbe1`](https://github.com/elm/regex/tree/a6d1b3e93b91a02bf4416c4ba314443b8bc3bbe1).
- [`elm/project-metadata-utils` 1.0.2 at `831733724fb2b59b38ba1639e6503d97607dbd9d`](https://github.com/elm/project-metadata-utils/tree/831733724fb2b59b38ba1639e6503d97607dbd9d).
- [`elm/color` at `156e512f9f566c8a66945336cac9dbf763c18c06`](https://github.com/elm/color/tree/156e512f9f566c8a66945336cac9dbf763c18c06).
- [`elm-explorations/test` 2.2.1 at `81dc48ee4edcc48661b0dfa969cf44a79318a321`](https://github.com/elm-explorations/test/tree/81dc48ee4edcc48661b0dfa969cf44a79318a321).
- [`avh4/elm-program-test` 4.0.1 at `9336741aaed9fc050136ba374b47a5c84f599f72`](https://github.com/avh4/elm-program-test/tree/9336741aaed9fc050136ba374b47a5c84f599f72).
- [`elm/compiler` 0.19.1 at `c9aefb6230f5e0bda03205ab0499f6e4af924495`](https://github.com/elm/compiler/tree/c9aefb6230f5e0bda03205ab0499f6e4af924495).
- [The official Elm guide at `df8f5e964e1ee7ca6610b856e16877d94af7aa98`](https://github.com/evancz/guide.elm-lang.org/tree/df8f5e964e1ee7ca6610b856e16877d94af7aa98).

These versions are the latest published package tags in the reviewed repositories.
The exception is the unpublished `elm/color` repository state.
The guide has no package tag, so the census pins its current commit.

The public package manifests define the module boundary.
See the pinned manifests for
[`elm/core`](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/elm.json#L1-L38),
[`elm/browser`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/elm.json#L1-L26),
[`elm-explorations/test`](https://github.com/elm-explorations/test/blob/81dc48ee4edcc48661b0dfa969cf44a79318a321/elm.json#L1-L41),
and [`elm-program-test`](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/elm.json#L1-L48).

Each contract below comes from public source documentation.
Implementation details appear only where they explain test control or ownership.

These classifications are evidence and not final Eta Crux decisions.
They do not decide adoption, deferral, or rejection.

## Classification key

- **plausible generic Eta Crux role**: The family can support a framework-neutral application, host, or test capability.
- **design evidence only**: The family supplies useful contracts or test patterns, but it has no clear generic Eta Crux role.
- **Elm-specific**: The family depends on the Elm compiler, Elm runtime, JavaScript boundary, or Elm UI representation.

## Census summary

The census contains 28 capability families.
The counts are 16 plausible generic roles, seven design-evidence families, and five Elm-specific families.

| Number | Capability family | Research classification |
|---:|---|---|
| 1 | Programs and runtime loop | plausible generic Eta Crux role |
| 2 | Flags and initialization input | plausible generic Eta Crux role |
| 3 | Messages, model transitions, and view projection | plausible generic Eta Crux role |
| 4 | Commands | plausible generic Eta Crux role |
| 5 | Subscriptions | plausible generic Eta Crux role |
| 6 | Tasks and typed asynchronous results | plausible generic Eta Crux role |
| 7 | Processes, sleep, and cancellation | plausible generic Eta Crux role |
| 8 | Effect managers and routers | Elm-specific |
| 9 | Ports | Elm-specific |
| 10 | Random generators and seeded execution | plausible generic Eta Crux role |
| 11 | Time and zones | plausible generic Eta Crux role |
| 12 | HTTP | plausible generic Eta Crux role |
| 13 | Files and downloads | plausible generic Eta Crux role |
| 14 | Bytes and binary codecs | design evidence only |
| 15 | Browser program adapters | design evidence only |
| 16 | Browser event subscriptions | design evidence only |
| 17 | Browser DOM tasks | design evidence only |
| 18 | Navigation, history, and URLs | design evidence only |
| 19 | HTML, SVG, and virtual DOM UI | Elm-specific |
| 20 | JSON boundary codecs | design evidence only |
| 21 | Development debugging | design evidence only |
| 22 | Unit tests, expectations, and fuzz tests | plausible generic Eta Crux role |
| 23 | Test execution and failure reports | plausible generic Eta Crux role |
| 24 | HTML query and event tests | Elm-specific |
| 25 | Whole-program deterministic driver | plausible generic Eta Crux role |
| 26 | Simulated commands, tasks, effects, and subscriptions | plausible generic Eta Crux role |
| 27 | Program boundary simulation and observation | plausible generic Eta Crux role |
| 28 | Compiler and package tooling | Elm-specific |

### Ticket-ready summary facts

- **First-party boundary:** 16 public package repositories plus `elm/compiler`.
- **Supplementary test boundary:** `elm-explorations/test` and `avh4/elm-program-test`.
- **Capability total:** 28 families.
- **Classification counts:** 16 plausible generic roles, seven design-evidence families, and five Elm-specific families.
- **Explicit pure or tooling dispositions:** `parser`, `regex`, `color`, and `project-metadata-utils`.
- **Non-package repository disposition:** Eight active websites, catalogs, policy repositories, and editor lists define no Elm program capability.

## Core program and effect families

### 1. Programs and runtime loop

- **Purpose:** `Program flags model msg` describes a runnable Elm program.
  `Platform.worker` creates a headless program.
- **Contract:** A worker supplies `init`, `update`, and `subscriptions`.
  The runtime stores the model and routes produced messages to `update`.
- **Test control:** `elm-program-test` mirrors worker and browser constructors.
  `start` initializes a retained simulated program state.
- **Ownership:** The Elm runtime owns the message loop, model storage, command dispatch, and subscription reconciliation.
  The application owns the three program functions.
- **Classification:** **plausible generic Eta Crux role**.
  A host-driven state-machine program is framework-neutral.
- **Sources:** [`Platform.Program` and `worker`](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Platform.elm#L36-L72)
  and [`ProgramTest` creation and start](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/ProgramTest.elm#L310-L461).

### 2. Flags and initialization input

- **Purpose:** Flags pass one host value to `init` when JavaScript starts a program.
- **Contract:** The runtime checks the value against the declared Elm flag type.
  An invalid value fails at the JavaScript boundary.
- **Test control:** `start` accepts typed flags.
  `withJsonStringFlags` also decodes a JSON string through the production flag decoder.
- **Ownership:** The host owns the input value.
  Elm owns boundary validation and delivers the value once during initialization.
- **Classification:** **plausible generic Eta Crux role**.
  Validated startup input is a generic host boundary.
- **Sources:** [official flag purpose, accepted values, and failure contract](https://github.com/evancz/guide.elm-lang.org/blob/df8f5e964e1ee7ca6610b856e16877d94af7aa98/book/interop/flags.md#L1-L144)
  and [`withJsonStringFlags`](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/ProgramTest.elm#L466-L493).

### 3. Messages, model transitions, and view projection

- **Purpose:** Messages represent program events.
  `update` converts one message and model into a new model plus commands.
  `view` projects UI data.
- **Contract:** Program constructors fix one message type for events, commands, subscriptions, and views.
  The next transition receives the current model.
- **Test control:** `ProgramTest.update` sends a message directly.
  `expectModel` inspects the resulting model, and view assertions inspect its projection.
- **Ownership:** The application owns message meaning and pure transition logic.
  The runtime owns transition order and current-model storage.
- **Classification:** **plausible generic Eta Crux role**.
  Typed events, transitions, and projections are generic state-machine concepts.
- **Sources:** [`Browser.element` program record](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Browser.elm#L79-L112)
  and [direct message and model controls](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/ProgramTest.elm#L644-L661).

### 4. Commands

- **Purpose:** `Cmd msg` describes managed work that can return messages to the application.
- **Contract:** `none` describes no work.
  `batch` starts its commands together and gives no result-order guarantee.
  `map` changes produced messages.
- **Test control:** `ProgramTest` captures command-like effects.
  Tests can inspect or simulate the latest effect without running a real host.
- **Ownership:** The runtime owns dispatch and effect-manager selection.
  The selected effect manager or host owns external execution.
- **Classification:** **plausible generic Eta Crux role**.
  Opaque command descriptions and typed returned events fit a generic application core.
- **Sources:** [`Cmd` managed-effect contract](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Platform/Cmd.elm#L8-L23)
  and [`none`, `batch`, and `map`](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Platform/Cmd.elm#L31-L85).

### 5. Subscriptions

- **Purpose:** `Sub msg` declares external event sources that can send messages.
- **Contract:** The runtime manages active subscriptions from the current model.
  `none`, `batch`, and `map` supply empty, combined, and message-mapped forms.
- **Test control:** `withSimulatedSubscriptions` interprets application-defined subscription data.
  Boundary helpers also inject time, port, and route events.
- **Ownership:** The runtime owns subscription reconciliation.
  An effect manager or host owns the event source.
  The application selects subscriptions from its model.
- **Classification:** **plausible generic Eta Crux role**.
  Host-owned event streams are a generic boundary requirement.
- **Sources:** [`Sub` purpose and managed lifecycle](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Platform/Sub.elm#L8-L49)
  and [`none`, `batch`, and `map`](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Platform/Sub.elm#L52-L84).

### 6. Tasks and typed asynchronous results

- **Purpose:** `Task error value` describes asynchronous work with typed success and failure results.
- **Contract:** `andThen` sequences successful tasks.
  `onError` handles failures.
  `sequence` runs tasks in order and stops after the first failure.
  `perform` and `attempt` convert tasks into commands.
- **Test control:** `SimulatedEffect.Task` creates pure simulated tasks.
  A custom effect interpreter can return a selected success or failure path.
- **Ownership:** The runtime scheduler owns task continuation.
  Effect implementations own external work.
  The application owns result mapping.
- **Classification:** **plausible generic Eta Crux role**.
  Typed asynchronous descriptions and explicit interpretation are generic.
- **Sources:** [`Task` result and description contract](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Task.elm#L38-L60),
  [sequential task composition](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Task.elm#L123-L209),
  and [`perform` and `attempt`](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Task.elm#L253-L351).

### 7. Processes, sleep, and cancellation

- **Purpose:** `Process` runs tasks concurrently, delays progress, and stops retained processes.
- **Contract:** `spawn` starts an interleaved lightweight process.
  `sleep` blocks that process for milliseconds.
  `kill` stops its task and aborts an in-flight HTTP request.
- **Test control:** `SimulatedEffect.Process.sleep` records a simulated delay.
  `advanceTime` releases due simulated work.
  The test package has no public simulator for arbitrary production process identifiers.
- **Ownership:** The Elm scheduler owns process progress and cancellation.
  The application owns process identifiers that it retains.
- **Classification:** **plausible generic Eta Crux role**.
  Spawn, controlled sleep, and cancellation are generic effect-lifecycle concerns.
- **Sources:** [`Process` concurrency and `spawn`](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Process.elm#L54-L84),
  [`sleep` and `kill`](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Process.elm#L87-L105),
  and [simulated sleep](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/SimulatedEffect/Process.elm#L1-L24).

### 8. Effect managers and routers

- **Purpose:** Effect modules implement the runtime handlers behind commands and subscriptions.
  Routers send messages to the application or to the manager itself.
- **Contract:** A manager receives command and subscription changes through compiler-recognized hooks.
  `sendToApp` enters the normal update loop.
  `sendToSelf` enters manager state handling.
- **Test control:** Normal application tests cannot install effect managers.
  `elm-program-test` simulates exposed effect data instead.
- **Ownership:** The Elm runtime owns manager creation, routing, and reconciliation.
  A trusted package owns manager state and external resources.
- **Classification:** **Elm-specific**.
  **Reason:** The contract uses Elm-only `effect module` syntax, kernel access, and compiler approval.
- **Sources:** [public warning and router helpers](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Platform.elm#L12-L25)
  and [`Router`, `sendToApp`, and `sendToSelf`](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Platform.elm#L94-L120).

### 9. Ports

- **Purpose:** Ports exchange application-owned data with JavaScript.
  Outgoing ports produce commands, and incoming ports produce subscriptions.
- **Contract:** Port values use the flag-compatible boundary types.
  Ports exist only in application `port module` files.
  Packages cannot declare them.
- **Test control:** Tests inspect decoded outgoing values by port name.
  They inject encoded incoming values by port name.
- **Ownership:** Elm owns encoding, decoding, and managed command or subscription integration.
  JavaScript owns external state and behavior.
- **Classification:** **Elm-specific**.
  **Reason:** Ports are compiler declarations tied to generated JavaScript and Elm application-package restrictions.
- **Sources:** [official outgoing and incoming port contracts](https://github.com/evancz/guide.elm-lang.org/blob/df8f5e964e1ee7ca6610b856e16877d94af7aa98/book/interop/ports.md#L55-L204),
  [official ownership and package restrictions](https://github.com/evancz/guide.elm-lang.org/blob/df8f5e964e1ee7ca6610b856e16877d94af7aa98/book/interop/ports.md#L205-L257),
  and [program-test port controls](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/ProgramTest.elm#L1742-L1860).

## Published host capability families

### 10. Random generators and seeded execution

- **Purpose:** `Random.Generator` describes pseudo-random values.
  `generate` turns a generator into a command that returns one message.
- **Contract:** Generators transform a seed into a value and next seed.
  `step` is pure and reproducible.
  `initialSeed` gives identical sequences for identical integers.
  The PCG implementation is not cryptographically secure.
- **Test control:** Tests use `initialSeed` and `step` to select exact sequences.
  `elm-program-test` has no dedicated interpreter for `Random.generate`.
- **Ownership:** Pure callers own explicit seeds.
  For `generate`, the Random effect manager owns a seed initialized from `Time.now`.
  The runtime owns command delivery.
- **Classification:** **plausible generic Eta Crux role**.
  Seeded generation and explicit deterministic control support reproducible application and law tests.
- **Sources:** [generator purpose and security limit](https://github.com/elm/random/blob/c1c9da4d861363cee1c93382d2687880279ed0dd/src/Random.elm#L1-L40),
  [`Generator`, `step`, and `initialSeed`](https://github.com/elm/random/blob/c1c9da4d861363cee1c93382d2687880279ed0dd/src/Random.elm#L662-L798),
  and [`generate` and manager initialization](https://github.com/elm/random/blob/c1c9da4d861363cee1c93382d2687880279ed0dd/src/Random.elm#L831-L879).

### 11. Time and zones

- **Purpose:** `Time` supplies POSIX time, local-zone data, calendar conversion, and periodic subscriptions.
- **Contract:** `now` reads time when its task runs.
  `every` requests periodic messages.
  `here` reports only the current offset and has documented daylight-saving limits.
- **Test control:** `ProgramTest.advanceTime` advances a virtual millisecond clock and runs due simulated tasks or subscriptions.
  `SimulatedEffect.Time.now` reads that virtual clock.
- **Ownership:** The host owns wall time and zone data.
  The time effect manager owns timer registration.
  The test driver owns virtual time.
- **Classification:** **plausible generic Eta Crux role**.
  Explicit time reads, ticks, and virtual time support deterministic programs.
- **Sources:** [`now`](https://github.com/elm/time/blob/7b97ef513b289d7b88704fcfc5a0807f7eb4f5ce/src/Time.elm#L59-L75),
  [`here` limits](https://github.com/elm/time/blob/7b97ef513b289d7b88704fcfc5a0807f7eb4f5ce/src/Time.elm#L146-L179),
  [`every`](https://github.com/elm/time/blob/7b97ef513b289d7b88704fcfc5a0807f7eb4f5ce/src/Time.elm#L573-L597),
  [`advanceTime`](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/ProgramTest.elm#L1695-L1734),
  and [simulated current time](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/SimulatedEffect/Time.elm#L1-L31).

### 12. HTTP

- **Purpose:** `Http` describes requests, bodies, headers, response expectations, cancellation, and progress tracking.
- **Contract:** Requests return through `expect`.
  `track` associates progress with a string key.
  `cancel` stops requests with that key.
- **Test control:** `ProgramTest` records requests and supplies selected HTTP responses.
  `Test.Http` builds response values for simulations.
- **Ownership:** The HTTP effect manager owns request execution, progress, and keyed cancellation.
  The application owns request data and response decoding.
- **Classification:** **plausible generic Eta Crux role**.
  Typed HTTP requests and deterministic response control form a reusable host capability.
- **Sources:** [`Http` public capability index](https://github.com/elm/http/blob/34a9a27411c2492d3e247ac75cd48e22b473bef5/src/Http.elm#L1-L67),
  [`request`, `track`, and `cancel`](https://github.com/elm/http/blob/34a9a27411c2492d3e247ac75cd48e22b473bef5/src/Http.elm#L515-L605),
  and [program-test HTTP controls](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/ProgramTest.elm#L1406-L1693).

### 13. Files and downloads

- **Purpose:** `File.Select` asks users for files.
  `File.Download` downloads URLs, strings, or bytes.
  `File` reads content and metadata.
- **Contract:** Selection must follow a user event and can remain unresolved after cancellation.
  Content reads return tasks.
  Metadata reads are synchronous.
  Downloads are one-shot commands with browser security constraints.
- **Test control:** No reviewed test package supplies a file selector, file value, content reader, or download simulator.
  Applications need a custom effect boundary for deterministic file tests.
- **Ownership:** The browser owns selectors, selected file handles, content storage, and downloads.
  Elm owns typed handles, tasks, commands, and result messages.
  The API exposes no close operation.
- **Classification:** **plausible generic Eta Crux role**.
  User-selected resources, asynchronous reads, metadata, and host-owned downloads form a generic host capability.
- **Sources:** [selection lifecycle and non-resolution](https://github.com/elm/file/blob/e4ca3864c93a5e766e24ed6916174753567b2f59/src/File/Select.elm#L1-L30),
  [single and multiple selection](https://github.com/elm/file/blob/e4ca3864c93a5e766e24ed6916174753567b2f59/src/File/Select.elm#L44-L111),
  [content tasks and metadata](https://github.com/elm/file/blob/e4ca3864c93a5e766e24ed6916174753567b2f59/src/File.elm#L35-L179),
  and [download commands and security constraints](https://github.com/elm/file/blob/e4ca3864c93a5e766e24ed6916174753567b2f59/src/File/Download.elm#L1-L109).

### 14. Bytes and binary codecs

- **Purpose:** `Bytes` represents binary data.
  Encoder and decoder modules build and parse protocol payloads.
  `getHostEndianness` reads host byte order.
- **Contract:** Encoding is pure.
  Decoding returns `Nothing` for insufficient or invalid bytes.
  Integer and float codecs take explicit endianness where it matters.
- **Test control:** Tests run encoders and decoders as pure functions with fixed bytes.
  The reviewed test tools have no dedicated control for the host-endianness task.
- **Ownership:** The application owns binary formats and codec composition.
  Elm owns byte storage and codec execution.
  The host owns the endianness value.
- **Classification:** **design evidence only**.
  Binary codec composition is useful boundary evidence.
  It owns no external resource lifecycle, apart from one host-property task.
- **Sources:** [`Bytes`, width, and host endianness](https://github.com/elm/bytes/blob/2bce2aeda4ef18c3dcccd84084647d22a7af36a6/src/Bytes.elm#L1-L138),
  [`Bytes.Encode` surface](https://github.com/elm/bytes/blob/2bce2aeda4ef18c3dcccd84084647d22a7af36a6/src/Bytes/Encode.elm#L1-L104),
  and [`Bytes.Decode` failure contract](https://github.com/elm/bytes/blob/2bce2aeda4ef18c3dcccd84084647d22a7af36a6/src/Bytes/Decode.elm#L1-L69).

## Browser and UI families

### 15. Browser program adapters

- **Purpose:** `Browser` creates sandbox, embedded-element, document, and single-page application programs.
- **Contract:** Each form adds a fixed host contract.
  `document` controls title and body.
  `application` also receives URL requests, URL changes, and a navigation key.
- **Test control:** `ProgramTest` has one parallel constructor for each browser form.
  A base URL supplies application startup context.
- **Ownership:** The browser runtime owns mounting, rendering, and browser callbacks.
  The application owns its model, transition, subscriptions, and view.
- **Classification:** **design evidence only**.
  The adapter progression gives useful host-boundary evidence, but each form targets browsers.
- **Sources:** [`sandbox`, `element`, and `document`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Browser.elm#L42-L164)
  and [`application`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Browser.elm#L168-L217).

### 16. Browser event subscriptions

- **Purpose:** `Browser.Events` subscribes to animation frames, visibility changes, resize events, and global keyboard or mouse events.
- **Contract:** Each function returns a managed `Sub`.
  Event decoders suppress messages when decoding fails.
- **Test control:** `ProgramTest.simulateDomEvent` injects decoded DOM events.
  It has no dedicated controls for visibility or animation-frame timestamps.
- **Ownership:** The browser owns event production.
  Elm owns listeners and decoder-to-message routing.
- **Classification:** **design evidence only**.
  Host event-source shape is useful, but the concrete events use browser APIs.
- **Sources:** [`Browser.Events` public groups](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Browser/Events.elm#L1-L42)
  and [event subscriptions](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Browser/Events.elm#L45-L187).

### 17. Browser DOM tasks

- **Purpose:** `Browser.Dom` focuses elements, reads viewport or element geometry, and changes scroll positions.
- **Contract:** Focus and geometry tasks fail when an element identifier is missing.
  Viewport setters return task completion.
- **Test control:** `elm-program-test` has no dedicated DOM-task simulator.
  Applications can expose these tasks through custom simulated effects.
- **Ownership:** The browser owns DOM state.
  Elm tasks own typed request and result delivery.
- **Classification:** **design evidence only**.
  Query and mutation tasks show a host capability pattern, but the data contract is browser DOM geometry.
- **Sources:** [`Browser.Dom` public API](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Browser/Dom.elm#L1-L35)
  and [focus, viewport, and element tasks](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Browser/Dom.elm#L38-L286).

### 18. Navigation, history, and URLs

- **Purpose:** Navigation commands change browser history or load pages.
  URL modules parse, build, and decompose addresses.
- **Contract:** `pushUrl` adds history without loading a page.
  `replaceUrl` changes the current entry.
  A `Navigation.Key` comes only from `Browser.application`.
- **Test control:** Tests set a base URL, inspect URL and history, simulate route changes, and observe full page changes.
- **Ownership:** The browser owns global location and page loads.
  Elm owns the application-history key and routes detected changes through messages.
- **Classification:** **design evidence only**.
  The authority token and history simulator are useful patterns, but their semantics are browser-specific.
- **Sources:** [navigation key and history commands](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Browser/Navigation.elm#L51-L140),
  [page-load commands](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Browser/Navigation.elm#L144-L183),
  and [program-test navigation controls](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/ProgramTest.elm#L1862-L1910).

### 19. HTML, SVG, and virtual DOM UI

- **Purpose:** `Html`, `Svg`, and `VirtualDom` describe UI nodes, attributes, event handlers, keyed children, and lazy subtrees.
- **Contract:** The runtime converts node descriptions into browser DOM updates.
  Keyed nodes preserve identity during child reconciliation.
  Lazy nodes reuse prior work when arguments are equal.
- **Test control:** HTML tests query the Elm node representation and simulate attached events.
  Program tests apply the same operations to the current view.
- **Ownership:** The application owns immutable node descriptions.
  The Elm virtual DOM runtime owns diffing, listeners, and DOM mutation.
- **Classification:** **Elm-specific**.
  **Reason:** The family depends on Elm `Html msg`, `Svg msg`, virtual nodes, and Elm runtime patch behavior.
- **Sources:** [`Html` node, map, and text surface](https://github.com/elm/html/blob/1affbf39efef4b4529110a567f706130c178a457/src/Html.elm#L1-L94),
  [`Svg` nodes and HTML embedding](https://github.com/elm/svg/blob/dfe97e8282f283f4a62b6645f633076cfd24f3f7/src/Svg.elm#L1-L100),
  [keyed nodes](https://github.com/elm/html/blob/1affbf39efef4b4529110a567f706130c178a457/src/Html/Keyed.elm#L1-L41),
  and [lazy nodes](https://github.com/elm/html/blob/1affbf39efef4b4529110a567f706130c178a457/src/Html/Lazy.elm#L1-L94).

### 20. JSON boundary codecs

- **Purpose:** `Json.Decode` validates external JSON values.
  `Json.Encode` creates values for JavaScript boundaries.
- **Contract:** Decoders return a typed success or structured error.
  Combinators define field, index, alternative, and dependent decoding.
- **Test control:** Tests call encoders and decoders as pure functions.
  Flags, ports, HTTP, and program-test boundary helpers use these values.
- **Ownership:** The application owns schemas and error policy.
  The host owns raw values.
  Elm owns decoder execution.
- **Classification:** **design evidence only**.
  Boundary validation is important evidence, but codecs are data utilities rather than an effect lifecycle.
- **Sources:** [`Json.Decode` contract and API groups](https://github.com/elm/json/blob/2865dfce97a75724a75583a214d3a287d2abecd4/src/Json/Decode.elm#L1-L76)
  and [`Json.Encode` contract](https://github.com/elm/json/blob/2865dfce97a75724a75583a214d3a287d2abecd4/src/Json/Encode.elm#L1-L47).

### 21. Development debugging

- **Purpose:** `Debug` converts values to strings, logs tagged values, and marks unfinished branches.
- **Contract:** `todo` raises an uncatchable runtime exception with source position.
  Debug functions are unavailable to packages and optimized builds.
- **Test control:** There is no debug capture API.
  Tests use expectations and runner failures instead.
- **Ownership:** The compiler and development runtime own debug metadata and console output.
  The application owns labels and placeholder text.
- **Classification:** **design evidence only**.
  Development-only fences and explicit unfinished-code failures are useful evidence, not application capabilities.
- **Sources:** [`Debug` availability and value conversion](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Debug.elm#L1-L38),
  [`log`](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Debug.elm#L41-L61),
  and [`todo`](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Debug.elm#L64-L96).

## Test and whole-program simulation families

### 22. Unit tests, expectations, and fuzz tests

- **Purpose:** `Test`, `Expect`, and `Fuzz` define example tests, assertions, generated inputs, shrinking, and distribution checks.
- **Contract:** A test evaluates to expectations.
  Fuzz tests generate cases and shrink failures.
  `todo`, `skip`, and `only` force suite-level failure signals.
- **Test control:** Seeds, run counts, fuzzers, and expectations define execution inputs and observations.
- **Ownership:** The test author owns generators and assertions.
  The runner owns case generation, shrinking, and suite selection.
- **Classification:** **plausible generic Eta Crux role**.
  Deterministic examples and generated state-machine traces can support generic laws.
- **Sources:** [`Test` creation and organization](https://github.com/elm-explorations/test/blob/81dc48ee4edcc48661b0dfa969cf44a79318a321/src/Test.elm#L1-L164),
  [fuzz-test API](https://github.com/elm-explorations/test/blob/81dc48ee4edcc48661b0dfa969cf44a79318a321/src/Test.elm#L346-L567),
  and [`Fuzz` generators](https://github.com/elm-explorations/test/blob/81dc48ee4edcc48661b0dfa969cf44a79318a321/src/Fuzz.elm#L1-L91).

### 23. Test execution and failure reports

- **Purpose:** `Test.Runner` converts a test tree into runnable tests and exposes structured outcomes.
  Failure modules define machine-readable reasons.
- **Contract:** Runner operations accept a fuzz count and seed.
  Each runnable test returns labels and an outcome.
- **Test control:** A custom runner selects seeds and fuzz counts.
  Normal users run the separate `elm-test` executable.
- **Ownership:** The runner owns traversal, random-state progression, and report structure.
  The test framework owns failure categories.
- **Classification:** **plausible generic Eta Crux role**.
  Seeded execution and structured counterexamples support reproducible capability tests.
- **Sources:** [`Test.Runner` API and warning](https://github.com/elm-explorations/test/blob/81dc48ee4edcc48661b0dfa969cf44a79318a321/src/Test/Runner.elm#L1-L86)
  and [public failure types](https://github.com/elm-explorations/test/blob/81dc48ee4edcc48661b0dfa969cf44a79318a321/src/Test/Runner/Failure.elm#L1-L90).

### 24. HTML query and event tests

- **Purpose:** `Test.Html.Query`, `Selector`, and `Event` inspect Elm HTML and simulate attached events.
- **Contract:** Queries select subtrees and assert selector matches.
  Event simulation decodes the supplied event value through the node handler.
- **Test control:** Tests choose selectors, event names, and JSON event fields.
  No browser or real DOM is required.
- **Ownership:** The test library owns virtual-node traversal and handler decoding.
  The test owns expected nodes and simulated event data.
- **Classification:** **Elm-specific**.
  **Reason:** Queries and event simulation inspect the private representation of Elm virtual DOM values.
- **Sources:** [`Test.Html.Query` surface](https://github.com/elm-explorations/test/blob/81dc48ee4edcc48661b0dfa969cf44a79318a321/src/Test/Html/Query.elm#L1-L61),
  [`Selector` surface](https://github.com/elm-explorations/test/blob/81dc48ee4edcc48661b0dfa969cf44a79318a321/src/Test/Html/Selector.elm#L1-L67),
  and [`Event.simulate` and `expect`](https://github.com/elm-explorations/test/blob/81dc48ee4edcc48661b0dfa969cf44a79318a321/src/Test/Html/Event.elm#L1-L145).

### 25. Whole-program deterministic driver

- **Purpose:** `ProgramTest` retains a complete simulated program, including its model, current view, effects, navigation, and failures.
- **Contract:** Program definitions mirror each Elm program constructor.
  `start` runs initialization.
  Operations return a new driver state.
  `done` converts accumulated state or failure into an expectation.
- **Test control:** Tests drive the state through UI actions, messages, time, routes, ports, HTTP responses, and custom effects.
- **Ownership:** The driver owns simulated model storage, effect history, navigation history, virtual time, and failures.
  The test owns each stimulus.
- **Classification:** **plausible generic Eta Crux role**.
  A persistent test shell with explicit boundaries is a direct generic Eta Crux pattern.
- **Sources:** [`ProgramTest` purpose and API index](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/ProgramTest.elm#L1-L197),
  [retained state](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/ProgramTest.elm#L232-L257),
  and [`done`](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/ProgramTest.elm#L2094-L2113).

### 26. Simulated commands, tasks, effects, and subscriptions

- **Purpose:** Simulated-effect modules replace application effect algebras with deterministic test descriptions.
  They cover commands, tasks, subscriptions, navigation, ports, process sleep, and HTTP.
- **Contract:** `withSimulatedEffects` maps each application effect into a simulated effect.
  `withSimulatedSubscriptions` does the same for subscriptions.
  Task combinators preserve success and failure sequencing.
- **Test control:** Tests inspect the latest effect, supply its result, advance time, or inject subscription values.
- **Ownership:** The test owns interpretation and result values.
  The driver owns scheduling and delivery of resulting messages.
- **Classification:** **plausible generic Eta Crux role**.
  A typed interpreter boundary is generic even though these adapters use Elm types.
- **Sources:** [simulation options](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/ProgramTest.elm#L480-L531),
  [`SimulatedEffect.Cmd`](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/SimulatedEffect/Cmd.elm#L1-L70),
  and [`SimulatedEffect.Task`](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/SimulatedEffect/Task.elm#L1-L82).

### 27. Program boundary simulation and observation

- **Purpose:** High-level helpers inspect views, HTTP requests, ports, URLs, history, models, and effects.
  They simulate user events and external responses.
- **Contract:** `expect*` functions finish with an expectation.
  `ensure*` functions add a failure to the retained driver and permit a continued scenario.
  Simulation failures also remain in driver state.
- **Test control:** Tests select exact interactions and responses.
  They can use low-level message, model, and effect controls when a high-level helper is absent.
- **Ownership:** The driver owns observation logs and failure accumulation.
  The test owns expected values and external responses.
- **Classification:** **plausible generic Eta Crux role**.
  Explicit observe, resolve, continue, and finish operations fit generic program tests.
- **Sources:** [view and interaction controls](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/ProgramTest.elm#L664-L1404),
  [HTTP controls](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/ProgramTest.elm#L1406-L1693),
  and [port and browser controls](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/ProgramTest.elm#L1742-L1910).

## Package-tooling family

### 28. Compiler and package tooling

- **Purpose:** The `elm` executable compiles applications and starts a local development server.
  It also opens a REPL, installs dependencies, publishes packages, selects semantic versions, and reports API differences.
- **Contract:** `elm.json` separates applications from packages.
  Application dependencies use exact versions.
  Package dependencies use compatible ranges.
  `bump`, `diff`, and `publish` apply Elm package-version rules.
- **Test control:** Tool tests can run commands against fixture projects and inspect exit reports.
  `elm-program-test` does not control compiler or package operations.
- **Ownership:** The compiler owns compilation, dependency solving, package checks, and generated JavaScript.
  The project owns source and `elm.json`.
  The package service owns published artifacts.
- **Classification:** **Elm-specific**.
  **Reason:** The family implements Elm syntax, Elm package metadata, Elm semantic-version enforcement, and the Elm package registry.
- **Sources:** [compiler command registry](https://github.com/elm/compiler/blob/c9aefb6230f5e0bda03205ab0499f6e4af924495/terminal/src/Main.hs#L61-L324),
  [application `elm.json` contract](https://github.com/elm/compiler/blob/c9aefb6230f5e0bda03205ab0499f6e4af924495/docs/elm.json/application.md#L1-L105),
  and [package `elm.json` contract](https://github.com/elm/compiler/blob/c9aefb6230f5e0bda03205ab0499f6e4af924495/docs/elm.json/package.md#L1-L144).

## Excluded public surfaces

These exclusions record why a public module or named surface does not create another architectural family.

| Excluded surface | Reason | Primary source |
|---|---|---|
| `Basics`, `String`, `Char`, `Bitwise`, and `Tuple` | Pure language and scalar utilities. They own no runtime capability or lifecycle. | [`elm/core` exposed modules](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/elm.json#L7-L13) |
| `List`, `Dict`, `Set`, and `Array` | Pure collection modules. They own no external effect or program boundary. | [`elm/core` exposed modules](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/elm.json#L14-L20) |
| `Maybe` and `Result` | Pure error and optional-value carriers. Task use appears in family 6. | [`elm/core` exposed modules](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/elm.json#L21-L25) |
| Time calendar conversion and custom-zone helpers | Pure data conversion inside family 11. They do not add effect ownership. | [`Time` module groups](https://github.com/elm/time/blob/7b97ef513b289d7b88704fcfc5a0807f7eb4f5ce/src/Time.elm#L26-L42) |
| HTTP body, header, response, error, and resolver values | Data and decoding contracts inside family 12. They share its request lifecycle. | [`Http` module groups](https://github.com/elm/http/blob/34a9a27411c2492d3e247ac75cd48e22b473bef5/src/Http.elm#L8-L67) |
| `Html.Attributes`, `Html.Events`, and the corresponding SVG modules | Node data constructors inside family 19. Their effects run through virtual DOM listeners. | [`elm/html` exposed modules](https://github.com/elm/html/blob/1affbf39efef4b4529110a567f706130c178a457/elm.json#L7-L17) and [`elm/svg` exposed modules](https://github.com/elm/svg/blob/dfe97e8282f283f4a62b6645f633076cfd24f3f7/elm.json#L7-L17) |
| HTML and SVG keyed or lazy modules | Rendering optimizations inside family 19. They do not define independent host work. | [`elm/html` exposed modules](https://github.com/elm/html/blob/1affbf39efef4b4529110a567f706130c178a457/elm.json#L14-L17) and [`elm/svg` exposed modules](https://github.com/elm/svg/blob/dfe97e8282f283f4a62b6645f633076cfd24f3f7/elm.json#L14-L17) |
| `Url.Builder`, `Url.Parser`, and `Url.Parser.Query` | Pure URL construction and parsing inside family 18. | [`elm/url` exposed modules](https://github.com/elm/url/blob/384b1dcf84065a500a71402ec367f3982b35093d/elm.json#L7-L12) |
| `elm/parser` | Pure parser composition over caller-provided text. It owns no host input, effect, or lifecycle. | [`Parser` public API](https://github.com/elm/parser/blob/02839df10e462d8423c91917271f4b6f8d2f284d/src/Parser.elm#L1-L91) |
| `elm/regex` | Pure regular-expression compilation and matching over caller-provided strings. It owns no effect lifecycle. | [`Regex` public API](https://github.com/elm/regex/blob/a6d1b3e93b91a02bf4416c4ba314443b8bc3bbe1/src/Regex.elm#L1-L48) |
| `elm/color` | Pure color values and color-space conversions. It has no published registry release and owns no program capability. | [`elm/color` package manifest](https://github.com/elm/color/blob/156e512f9f566c8a66945336cac9dbf763c18c06/elm.json#L1-L27) and [`Color.Rgb`](https://github.com/elm/color/blob/156e512f9f566c8a66945336cac9dbf763c18c06/src/Color/Rgb.elm#L1-L42) |
| `elm/project-metadata-utils` | Pure models and decoders for `elm.json`, `docs.json`, and compiler reports. It refines family 28 but performs no file I/O. | [tooling scope and read-only cache guidance](https://github.com/elm/project-metadata-utils/blob/831733724fb2b59b38ba1639e6503d97607dbd9d/README.md#L1-L20) and [exposed modules](https://github.com/elm/project-metadata-utils/blob/831733724fb2b59b38ba1639e6503d97607dbd9d/elm.json#L7-L23) |
| `Test.Distribution` | A fuzz-test assertion refinement inside family 22. | [`Test.Distribution`](https://github.com/elm-explorations/test/blob/81dc48ee4edcc48661b0dfa969cf44a79318a321/src/Test/Distribution.elm#L1-L54) |
| `SimulatedEffect.Navigation`, `Ports`, `Process`, `Time`, `Http`, `Cmd`, `Sub`, and `Task` as separate modules | Adapters for families 7, 9, 11, 12, 18, 26, and 27. They do not own separate driver lifecycles. | [`elm-program-test` exposed modules](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/elm.json#L7-L21) |
| `Test.Http` | HTTP response fixtures inside families 12 and 27. | [`Test.Http`](https://github.com/avh4/elm-program-test/blob/9336741aaed9fc050136ba374b47a5c84f599f72/src/Test/Http.elm#L1-L47) |
| Compiler parsers, optimizers, code generators, dependency solver, and report renderers | Internal parts of family 28. The compiler does not publish them as application capabilities. | [`elm/compiler` source layout](https://github.com/elm/compiler/tree/c9aefb6230f5e0bda03205ab0499f6e4af924495) |
| Examples, benchmarks, repository tests, and upgrade guides | Evidence and maintenance material, not public runtime families. | [`elm-program-test` repository root](https://github.com/avh4/elm-program-test/tree/9336741aaed9fc050136ba374b47a5c84f599f72) |
| `elm-lang.org`, `package.elm-lang.org`, and `foundation.elm-lang.org` | Product websites. Their application code consumes capabilities but does not publish a first-party program capability. | [`elm-lang.org`](https://github.com/elm/elm-lang.org/tree/75ad24740412f1bf72912d5125773ecdf271fd4b), [`package.elm-lang.org`](https://github.com/elm/package.elm-lang.org/tree/afe1a128b4bbf5ec0ebc21886d32b0b473794a9e), and [`foundation.elm-lang.org`](https://github.com/elm/foundation.elm-lang.org/tree/8790ef6dc647965ececf0b383e2b86f81b3a6e23) |
| `projects` and `error-message-catalog` | A collaboration catalog and compiler-error fixtures. They contain evidence or examples, not public package contracts. | [`projects`](https://github.com/elm/projects/tree/0d0f52abb320d1370aa7b6abc7e1007ba4c524ab) and [`error-message-catalog`](https://github.com/elm/error-message-catalog/tree/8f75db9fa745443f385ffd3c478fe1113d22c547) |
| `forum-rules` and `expectations` | Policy and process documents. They define community behavior, not runtime or test capabilities. | [`forum-rules`](https://github.com/elm/forum-rules/tree/9b4d38231692f984da6d5a1833c15a689105d80e) and [`expectations`](https://github.com/elm/expectations/tree/00adc8ac1004bdf099bcadc4f4489959b9ea8f59) |
| `editor-plugins` | A catalog of external editor integrations. It publishes no Elm package or editor capability implementation. | [`editor-plugins`](https://github.com/elm/editor-plugins/tree/9ed6a889117b16409e027312826b9152c6cbc8c0) |

## Coverage check

| Public source group | Census disposition |
|---|---|
| `elm/core` effect modules | Families 1 and 3 through 8 |
| Official flags and ports | Families 2 and 9 |
| `elm/random` | Family 10 |
| `elm/time` | Family 11 |
| `elm/http` | Family 12 |
| `elm/file` | Family 13 |
| `elm/bytes` | Family 14 |
| `elm/browser` | Families 15 through 18 |
| `elm/html`, `elm/svg`, and `elm/virtual-dom` | Family 19 |
| `elm/url` | Family 18 |
| `elm/json` | Family 20 |
| `elm/parser`, `elm/regex`, and `elm/color` | Excluded pure data surfaces |
| `elm/project-metadata-utils` | Excluded refinement of family 28 |
| `elm/core` debug API | Family 21 |
| `elm-explorations/test` | Families 22 through 24 |
| `elm-program-test` | Families 25 through 27, with controls recorded in production families |
| `elm/compiler` public commands and project format | Family 28 |
| Other active `elm` organization repositories | Excluded websites, catalogs, fixtures, policy repositories, and editor lists |

## Residual evidence gaps

- Elm package tags are old, but their repositories do not mark newer published versions.
  This census does not infer future compiler or runtime plans from issue discussions.
- The official guide has no release tag.
  Its pinned commit is authoritative prose, but it is not versioned with Elm 0.19.1.
- `elm-program-test` simulates public behavior without running the Elm kernel.
  Exact equivalence for command batching, subscription reconciliation, and event-loop ordering is not a public theorem.
- `elm-program-test` has dedicated HTTP, time, port, and navigation controls.
  It has no dedicated simulator for random commands, files, bytes endianness, browser events, DOM tasks, or process identifiers.
- Public `Platform` exposes effect-manager router types, but normal packages cannot define new effect modules.
  The complete manager lifecycle remains a compiler and kernel contract.
- The reviewed sources do not specify a general resource bracket or finalizer law.
  Process kill and HTTP cancellation cover named operations only.
  The file API exposes no explicit close operation.
- The compiler repository defines the main `elm` commands.
  Separate editor tools and third-party runners are outside this first-party capability baseline.
- Repository activity and registry publication are different facts.
  `elm/color` remains public and non-archived, but the package registry does not list it.
