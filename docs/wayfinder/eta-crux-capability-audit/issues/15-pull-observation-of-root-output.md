# Pull observation of root output

Type: grilling
Status: open
Blocked by: 01, 02, 03, 04, 05, 06, 07

## Question

Does Eta Crux need pull observation of the latest committed root output?

Check whether hosts must cache pushed delivery and whether all safe pull
semantics already follow from the advancement and delivery fences. Distinguish
the latest committed output from the latest successfully delivered output.

Decide whether to adopt, defer with a precise condition, or reject the
capability. If adopted, specify the API shape, availability, consistency,
concurrency, lifetime, failure, laws, test controls, ownership, and migration
effects.
