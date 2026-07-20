# Reviewer questions

## Are these IDs unique everywhere?

No. They are unique and strictly increasing only within one runtime. A second
runtime or a runtime on another domain may issue the same integer or formatted
name. Cross-runtime correlation must add an application-owned namespace, such as
a deployment/runtime identifier.

## What happens on a second run of the same test?

A newly created `Eta_test` runtime starts a new counter, so the same program gets
the same sequence. Reusing the same runtime continues its existing sequence;
create a fresh test runtime when replay from the initial value is required.
