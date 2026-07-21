# DX-E20 reviewer questions

1. Which combinator drops records?
2. In what order do filter, attributes, and intercept run?
3. Which interceptor runs first when scopes are nested?
4. Does moving `with_logger` inside or outside `intercept_log` bypass the
   transform?
5. Is the metric example compelling enough to retain `intercept_metric`?

## Reviewer key

1. `intercept_log` drops a record when its transform returns `None`;
   `with_minimum_log_level` also drops below-threshold records before any
   interceptor can observe them.
2. Scoped minimum-level filter → scoped attributes → per-call attributes →
   intercept transforms → currently bound sink.
3. Outermost-to-innermost. `None` prevents all later/inner transforms.
4. No. Both nesting orders transform before the selected sink.
5. Compare `metric-old.ml`'s runtime-wide meter replacement with
   `metric-new.ml`'s lexical tenant scope; answer independently of the log case.
