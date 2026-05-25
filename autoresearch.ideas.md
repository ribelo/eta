# Deferred Optimizations

## Eta v2 watchlist items (from current session)

### pure.reused_rt: Eio entry-point overhead (~2 µs)
- **Cost breakdown**: Eio.Switch.run (~500 ns) + Eio.Fiber.with_binding (~500-1000 ns) + frame record (~50 ns) + with_finalizers (~50 ns) + eval (~10 ns)
- **Bottleneck**: Cannot eliminate Switch.run or Fiber.with_binding without restructuring Runtime.run to skip them for trivial effects
- **Frame caching**: Store a pre-allocated frame template with mutable sw/finalizers. Saves ~50 ns (2.5%). Not worth the complexity.
- **Switch-less fast path**: Add `Runtime.run_simple` that skips Switch + finalizers for effects known to be pure/fail. Semantically correct but changes API.
- **Verdict**: ~2 µs is acceptable for the entry point. v1 was ~48 ns but used a pure OCaml interpreter without Eio context. The Eio overhead is the price of integration.

### fail_catch: chain rebuilding allocation (RESOLVED)
- **Achieved**: 6.29M → 1.05M minor words (-83%). Matches v1 baseline.
- **Catch direct eval**: Saves inner frame + Eio.with_binding per catch (-50%)
- **Prebuilt chain**: Construction-time node allocation, handlers return prebuilt next nodes (-67%)
- **Remaining**: 10.5 words/iter = Cause.Fail + Exit.Error wrapping. Fundamental, cannot eliminate.

### bind.100k.prebuilt: zero-allocation invariant
- **Status**: 0 minor words, ~3.4 ns per bind. At the performance ceiling.

### retry.flaky.fail4_then_ok: zero-allocation invariant
- **Status**: 0 minor words, ~28 µs. At the performance ceiling.

## From previous HTTP session

## Upgrading mirage-crypto / ocaml-tls (blocked by digestif/OxCaml)
- **Impact**: High — remaining ~1.3ms TLS overhead per 1MB could be reduced significantly
- **Blocked by**: digestif 1.3.0 fails to compile with OxCaml local-mode (`By.t` vs `bytes @ local` issue)
- **Workaround**: Compile with plain OCaml 5.2 (not OxCaml), or upstream digestif fix
- **Key finding**: h2c (plain H2) GET 1M is 0.35ms vs Go 0.17ms — only 2× off. TLS adds ~1.0ms overhead.

## body_stream_async batching with state machine (oracle #7)
- **Idea**: Replace `scheduled`/`eof` bool refs with explicit `type read_state = Idle | Scheduled | Done` state machine
- **Approach**: Batch chunks in consumer side (pop multiple chunks from queue under one lock), flush on EOF or batch-full
- **Expected impact**: Small — maybe -0.05 to -0.25ms. The per-chunk overhead is now minimal after Security.observe and Informational_filter optimizations.
- **Risk**: Previous batching attempt deadlocked. State machine should fix it.

## Body.Stream.read_all fast path (oracle #6)
- **Idea**: When content-length is known, pre-allocate final buffer and copy H2 chunks directly into it
- **Approach**: Add optional `content_length` parameter to body_stream_async; allocate Bytes.create once; each on_read copies to appropriate offset
- **Expected impact**: Small — eliminates list accumulation and final concatenation. But these are <0.05ms based on synthetic benchmark.

## ocaml-tls send_buf optimization
- **Idea**: Like recv_buf, tls-eio's write path may benefit from larger buffers
- **Expected impact**: Unknown. The write_t function in tls_eio.ml uses Flow.copy_string per record.

## Learned lessons from this session (May 25)
1. **tls-eio recv_buf** was the biggest single TLS win: 4KB→256KB saved ~0.6ms for 1MB
2. **Security.observe batch-skip** was the biggest CPU win: avoiding 1M per-byte Bigstringaf.get calls saved ~1.0ms
3. **Informational_filter** had two wins: offset tracking (eliminated O(N²) string copying) and zero-copy DATA pass-through
4. **h2_write_fixed_body_sync no-flush** regressed POST — per-chunk flush is needed for request-body latency
5. **Larger reader buffer** (64KB→128KB→256KB) had diminishing returns but net positive
6. **Bigstringaf.of_string** in POST body writing was wasteful — direct write_string is better
7. **Diagnostic h2c scenario** proved TLS is the remaining bottleneck (plain H2 within 2× of Go)
