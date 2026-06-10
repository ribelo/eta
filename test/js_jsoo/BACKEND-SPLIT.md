# Backend Split

`test/js_jsoo` is js_of_ocaml integration coverage, not a native backend
backend matrix suite. The executables compile to JavaScript with
`js_of_ocaml --effects=cps` and run under Node.

`test_eta_jsoo.ml` checks the JavaScript-native runtime wrapper:

- timer delay and timeout/finalizer behavior in the JS event loop;
- `Eta_jsoo.Private.await` cancellation hooks;
- runtime locals, stream FIFO behavior, and daemon drain through the JS runtime
  contract.

`test_eta_js_jsoo.ml` checks the `Eta_js` facade in JavaScript:

- effect construction, typed failures, defects, finalizers, retry/repeat,
  concurrency combinators, and queue/channel/semaphore/pubsub/supervisor
  facades.

Equivalent native Eta-owned semantics live in the shared Eio suites. These
tests stay JS-specific because they verify js_of_ocaml output, Node execution,
and JS-facing facade modules.
