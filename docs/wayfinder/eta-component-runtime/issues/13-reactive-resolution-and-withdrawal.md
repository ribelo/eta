# Reactive resolution and withdrawal

Type: prototype
Status: open
Blocked by: 08, 10, 12

## Question

How does the runtime resolve providers and react when a required provider
appears, disappears, or changes identity?

Prototype dependency satisfaction, committed provider views, notification,
replacement, cycles, and a provider with several dependent levels. Include a
dependent whose asynchronous teardown still needs the departing provider.

Decide the withdrawal guard and prove that it releases. State whether duplicate
providers fail at admission or use another explicit mechanism.
