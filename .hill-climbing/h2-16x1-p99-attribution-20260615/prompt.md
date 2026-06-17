# Hill-Climbing Prompt

Use $hill-climbing on `.hill-climbing/h2-16x1-p99-attribution-20260615`.

Objective: improve or explain `h2_tls_16x1_root_p99_us` without gaming or
overfitting the benchmark. The workload is H2 with 16 connections and 1 stream
per connection. The primary steady-state signal is 24k requests x 9 repeats.
The facade also emits a 3200-request broad-floor root diagnostic to test whether
the quick-suite p99 is polluted by connection/preface startup.

Files in scope:
- `.hill-climbing/h2-16x1-p99-attribution-20260615/measure.sh`
- `.hill-climbing/h2-16x1-p99-attribution-20260615/checks.sh`
- `.hill-climbing/h2-16x1-p99-attribution-20260615/JOURNAL.md`
- H2/TLS server implementation files only after attribution points there.

Run measurements only through:

```bash
python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-16x1-p99-attribution-20260615
```

After each experiment, update `JOURNAL.md` manually with the hypothesis split,
prediction, result, verdict, and next experiment.
