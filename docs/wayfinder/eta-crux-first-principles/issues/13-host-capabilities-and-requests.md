# Host capabilities and request-response

Type: grilling
Status: open
Blocked by: 05, 07, 10

## Question

Does Eta Crux core need a typed capability-message or request-response protocol
for host-owned work, or can applications express it with staged effects and
adapter-specific services?

Test the decision against dialogs, file pickers, clipboard access, window
control, and one long-lived host source. Decide:

- whether request identity and exactly-once resolution are framework concepts.
- whether inbound host asks are supported as well as outbound requests.
- cancellation when the owning dynamic scope disappears.
- late, duplicate, missing, and streaming responses.
- whether in-process typed calls differ from cross-process serialized calls.
- which failures belong to Eta Crux, the application protocol, or the adapter.

Do not copy Rust Crux request machinery merely because it exists. Do not leave
every adapter to rebuild a protocol if Eta Crux owns a real invariant.
