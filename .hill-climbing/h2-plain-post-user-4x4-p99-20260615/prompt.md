# Hill-Climbing Prompt

Set up and climb the H2 plain `post_user` 4x4 p99 hill against Node h2c.

The current broad suite after the H1 echo fix shows Eta H2 plain `POST /user`
under `connections=4`, `streams=4` with stable p99 around `637us`, while Node
h2c is around `258us` on the same shape. This is the next candidate because it
is both stable in the broad repeats and worse than the relevant reference.

Run:

```sh
python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-plain-post-user-4x4-p99-20260615
```

Primary metric:

```text
h2_plain_post_user_4x4_eta_node_p99_ratio
```

Lower is better. Do not special-case `/user`, Node, oha, empty request bodies,
or this exact stream shape. Preserve H2 root/user/static/echo guardrails and
exact status/body validation.
