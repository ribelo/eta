# DX-E37 surface and footgun census

Baseline is the sealed-prediction commit `4e3524cf`; current is the E37 worktree.

| Measure | Baseline | Current | Delta |
| --- | ---: | ---: | ---: |
| Top-level `val` declarations in `lib/eta/effect.mli` | 129 | 130 | +1 |
| Public modules/types | unchanged | unchanged | +0 |
| `Effect.Expert` calls in the ordinary homogeneous recipe block | 6 | 0 | -6 calls |
| Homogeneous parallel-acquire Expert footgun | present | closed by `acquire_all_par` | -1 |
| New silent/default/fallback footguns | 0 | 0 | +0 |

Commands:

```sh
git show 4e3524cf:lib/eta/effect.mli | grep -c '^val '  # 129
grep -c '^val ' lib/eta/effect.mli                      # 130
git show 4e3524cf:docs/api-dx.md | sed -n '481,514p' | grep -c 'Effect.Expert'  # 6
sed -n '481,497p' docs/api-dx.md | grep -c 'Effect.Expert'                       # 0
```

The remaining `Effect.Expert` mention is outside the ordinary recipe and is
explicitly limited to heterogeneous library-integration work. No compatibility
path or alternate homogeneous spelling was added.
