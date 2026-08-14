# Temporal ownership and recovery

Type: prototype
Status: claimed
Blocked by: 03, 04, 06, 08, 09

## Question

What is the smallest context operation that tracks long-lived component effects
while Eta scopes retain lexical resource ownership?

Prototype registration, acquisition, child-component creation, partial
activation failure, cancellation, and repeated disposal. Compare explicit
inverse accumulation with scope-owned finalizers and derived child contexts.

The answer must define at-most-once behavior, recovery order, the observation
boundary, and the contract for an operation that cannot be reversed.
