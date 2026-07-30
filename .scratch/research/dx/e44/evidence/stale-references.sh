#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../../../../.."

moved='with_error_pp|suppress_observability|with_logger|with_tracer|named|annotate|annotate_all|annotate_all_lazy|is_tracing_enabled|event|with_result_attrs|link_span|with_external_parent|with_context|current_span|current_context|annotate_logs|with_minimum_log_level|intercept_log|log|logf|log_trace|log_debug|log_info|log_warn|log_error|log_fatal|intercept_metric|metric_update|metric_counter|metric_gauge|metric_frequency|metric_histogram|metric_summary|metric_timer|metric|metric_updates|metric_updates_lazy|here_attr|fn'

old_effect="$({
  rg -n --glob '*.ml' --glob '*.mli' \
    "\\b(?:Eta\\.)?Effect\\.(${moved})\\b" \
    lib test bench examples http-testsuite || true
} | grep -Ev 'leaf_name:|invalid_arg "Effect\.with_external_parent' || true)"

old_modules="$(rg -n --glob '*.ml' --glob '*.mli' \
  '\bEta\.(Logger|Meter|Tracer|Log_level|Trace_context)\b' \
  lib test bench examples http-testsuite || true)"

old_intercepts="$(rg -n --glob '*.ml' --glob '*.mli' \
  '\b(?:Eta\.)?Effect\.(Keep|Drop|Replace)\b' \
  lib test bench examples http-testsuite || true)"

if [[ -n "$old_effect$old_modules$old_intercepts" ]]; then
  printf '%s\n' "$old_effect" "$old_modules" "$old_intercepts"
  exit 1
fi

echo "zero stale observability code references"
