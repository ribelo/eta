# A2 streaming SSE probe

Question: can eta-ai parse provider SSE streams over eta-http response bodies
with bounded memory, typed provider errors, tool-call delta accumulation, and
clean cancellation?

What this probe tests:

- OpenAI chat-completion chunks with data: [DONE].
- Anthropic named events with content_block_delta and input_json_delta.
- OpenRouter chat-completion chunks with a mid-stream error object.
- Provider error events becoming typed AI events, not parser failures.
- Early downstream stop calling eta-http Body.Stream.discard exactly once.
- A VmRSS sample across repeated parses, plus max parser buffer size.

Run:

    nix develop -c bash scratch/eta_ai_v1/probes/streaming_sse/run.sh

Current result:

    sse_probe=ok
    openai_events=5 openai_max_buffer=233
    anthropic_events=9 anthropic_max_buffer=189
    openrouter_events=2 openrouter_max_buffer=258
    early_stop_release_count=1
    rss_delta_kib=8616 max_buffer=233

Failure modes this probe keeps visible:

- eta-http Body.Stream is sufficient for pull reads and release/discard.
- eta-stream does not yet expose a public owned pull-source constructor with a
  finalizer. Existing Mailbox and from_eio_stream constructors cannot prove
  downstream cancellation releases the upstream body.
- The required eta-stream extension is filed as
  packages/eta-stream/docs/adrs/0001-effect-reader-stream.md.
