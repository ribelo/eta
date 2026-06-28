# A2 verdict

Status: accepted with an eta-stream extension filed.

Decision:

- SSE framing and provider decoding can be implemented over eta-http
  Body.Stream without changing eta-http.
- eta-ai should not bury a custom long-lived producer/mailbox bridge to expose
  SSE as Stream.Stream.
- Stream needs a public owned effect-reader stream constructor that runs a
  finalizer on EOF, downstream stop, downstream failure, and interruption.

Evidence:

- The scratch parser handles chunk boundaries across SSE records and JSON string
  fragments.
- OpenAI tool-call argument chunks accumulate to {"location":"SF"} and the
  stream terminates on data: [DONE].
- Anthropic input_json_delta.partial_json chunks accumulate to
  {"location":"SF"} and the stream terminates on message_stop.
- OpenAI and Anthropic error events and OpenRouter mid-stream errors surface as
  Ai_error events, not parser failures.
- Early stop after one parsed OpenAI event calls the eta-http body release hook
  once; a second discard is idempotent.
- The repeated parse RSS sample stayed bounded for this fixture set:
  rss_before_kib=25864, rss_after_kib=34480, rss_delta_kib=8616,
  max_buffer=233.

Verification:

    nix develop -c bash .scratch/research/evidence/eta_ai_v1/probes/streaming_sse/run.sh
    exit 0

    ok openai text deltas
    ok openai tool args
    ok openai done
    ok anthropic text deltas
    ok anthropic tool args
    ok anthropic done
    ok openai error is typed event
    ok anthropic error is typed event
    ok openrouter error is typed event
    ok early stop released body
    ok release idempotent
    ok memory probe rss sample

Disproof signature outcome:

- Not triggered for eta-http. Body.Stream already gives read, EOF release, and
  explicit discard. Existing eta-http h1/h2 tests bind body discard to checkout
  and stream-permit release.
- Triggered for eta-stream. A public Stream.Stream source cannot currently
  be built from an effectful pull reader while preserving an upstream finalizer
  under downstream take/cancel. Mailbox.to_stream and from_eio_stream leave
  producer ownership outside the stream, so they do not prove cancellation of
  the eta-http body.

Phase A-C implication:

- eta-ai streaming should wait for the eta-stream source primitive or use an
  internal non-public parser only inside A2/A-C scaffolding.
- The public eta-ai streaming API should return Stream.Stream only after
  the source primitive lands.
- No eta-http API change is justified by A2.
