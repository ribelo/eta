# Operational metrics in Bonsai and Rust Crux

## Question

Do Bonsai or Rust Crux provide production metrics for queue depth, pending
requests, live structure, or aggregation across multiple roots?

## Bonsai

Bonsai provides graph profiling and debugging facilities. Its instrumentation
can wrap each computation node with timers. It can also publish graph
information to profiling tools.

The driver defines timers for startup and frame phases. The interface states
that these events are arbitrary and can change. Bonsai also exposes static graph
node counts through `Debug.bonsai_node_counts`.

Some private evaluator paths increment `Ui_metrics` counters for exceptional
conditions. Examples include dropped switch actions and actions sent to the
wrong leaf type.

These facilities do not define a stable production contract for queue depth,
pending requests, live dynamic structure, or aggregation across several Bonsai
applications.

Sources at Bonsai commit
[`1e4682c1`](https://github.com/janestreet/bonsai/tree/1e4682c1312e737aa94554139a28ebcd0c077bd6):

- [`src/instrumentation.mli`](https://github.com/janestreet/bonsai/blob/1e4682c1312e737aa94554139a28ebcd0c077bd6/src/instrumentation.mli)
- [`src/driver/instrumentation.mli`](https://github.com/janestreet/bonsai/blob/1e4682c1312e737aa94554139a28ebcd0c077bd6/src/driver/instrumentation.mli)
- [`src/cont.mli`](https://github.com/janestreet/bonsai/blob/1e4682c1312e737aa94554139a28ebcd0c077bd6/src/cont.mli#L1091-L1109)
- [`src/private_gather/gather_switch.ml`](https://github.com/janestreet/bonsai/blob/1e4682c1312e737aa94554139a28ebcd0c077bd6/src/private_gather/gather_switch.ml#L145-L164)

## Rust Crux

The Rust Crux production API documents events, models, commands, effects, and
shell requests. It does not document built-in production metrics for queue
depth, pending requests, live structure, or aggregation across multiple cores.

Crux issue 530 proposes event-lifecycle tracking. The discussion identifies
telemetry and metrics as desired uses. The discussion does not describe an
accepted or implemented production metrics contract.

Sources:

- [Crux core API](https://redbadger.github.io/crux/master_api_docs/crux_core/)
- [Crux overview](https://redbadger.github.io/crux/)
- [Proposal: Event tracking](https://github.com/redbadger/crux/issues/530)

## Conclusion

Neither framework supplies the root-local operational metric set proposed for
Eta Crux. Bonsai supplies detailed profiling and graph-debugging tools. Rust
Crux leaves comparable production telemetry to applications and shells, with
event tracking still under discussion.

The proposed Eta Crux count samples are a new design. They do not follow from a
reference framework. A smaller V1 metric contract is the safer default.
