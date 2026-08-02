# Host capabilities and request-response

Type: grilling
Status: open
Blocked by: 05, 07, 10

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

One-shot resolution is separate from repeated state-machine endpoints. Do not
copy Rust Crux request machinery merely because it exists.
