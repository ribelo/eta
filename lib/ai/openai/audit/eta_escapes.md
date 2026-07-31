# Eta-Primitive-Escape Audit

Run: bash lib/ai/openai/audit/run.sh
Current sites: 14

Sites where eta-ai-openai reaches into raw Eio fiber/switch/promise/mutex/
condition primitives or raw Atomic.t are listed here.

Search:

    rg -n -t ocaml 'Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.[A-Za-z0-9_]+' lib/ai/openai

## Replaceable

No replaceable escapes yet.

## Structural

No structural escapes in the audited provider package. Eio-backed tests live
under top-level test directories and are outside this package audit.

## Debt

No debt escapes yet.

## Current Matches

<!-- BEGIN ESCAPE_MATCHES -->
- lib/ai/openai/audio_sse.ml:38:  released : bool Atomic.t;
- lib/ai/openai/audio_sse.ml:39:  active : bool Atomic.t;
- lib/ai/openai/audio_sse.ml:88:    released = Atomic.make false;
- lib/ai/openai/audio_sse.ml:89:    active = Atomic.make false;
- lib/ai/openai/audio_sse.ml:109:    (E.sync (fun () -> Atomic.compare_and_set stream.released false true)
- lib/ai/openai/audio_sse.ml:122:  (E.sync (fun () -> Atomic.compare_and_set stream.active false true)
- lib/ai/openai/audio_sse.ml:127:           |> E.finally (E.sync (fun () -> Atomic.set stream.active false))))
- lib/ai/openai/speech.ml:367:  audio_released : bool Atomic.t;
- lib/ai/openai/speech.ml:368:  audio_active : bool Atomic.t;
- lib/ai/openai/speech.ml:376:         Atomic.compare_and_set stream.audio_released false true)
- lib/ai/openai/speech.ml:385:       Atomic.compare_and_set stream.audio_active false true)
- lib/ai/openai/speech.ml:391:                (E.sync (fun () -> Atomic.set stream.audio_active false))))
- lib/ai/openai/speech.ml:484:                audio_released = Atomic.make false;
- lib/ai/openai/speech.ml:485:                audio_active = Atomic.make false;
<!-- END ESCAPE_MATCHES -->
