# Host capabilities and request-response

Type: grilling
Status: open
Blocked by: 05, 07, 08, 10, 11

## Question

What typed request-response contract lets returned Eta effects ask the shell to
perform host-owned work through either local or serialized transport?

Test the decision against dialogs, file pickers, clipboard access, window
control, and one long-lived host source. Decide:

- whether request identity and exactly-once resolution are framework concepts.
- whether inbound host asks are supported as well as outbound requests.
- cancellation when the owning dynamic scope disappears.
- late, duplicate, missing, and streaming responses.
- whether in-process typed calls differ from cross-process serialized calls.
- which failures belong to Eta Crux, the application protocol, or the adapter.
- how `Ingress_closed` affects request admission and pending resolution.
- how root crash settlement closes unresolved host requests.

One-shot resolution is separate from repeated state-machine endpoints. Do not
copy Rust Crux request machinery merely because it exists.

Long-lived repeated host events use the generic producer from [Long-lived
sources and subscriptions](08-subscriptions-and-sources.md). This ticket owns
one-shot request resolution and does not add another streaming response path.

[Failure, defect, and crash boundary](11-failure-boundary.md) keeps admission
closure separate from interruption and root crash. The request protocol must
preserve those distinctions.
