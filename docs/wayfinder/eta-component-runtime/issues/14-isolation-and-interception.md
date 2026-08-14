# Isolation and interception

Type: prototype
Status: open
Blocked by: 02, 10, 13

## Question

How will Eta represent scoped coeffect isolation and interception without
weakening typed access or reactive provider identity?

Prototype derived contexts, realm identity, provider lookup, interception
metadata, and realm reassignment. Include two instances that use one logical
key but resolve different providers.

Decide which operations trigger reactivation and which operations change only
future access behavior.
