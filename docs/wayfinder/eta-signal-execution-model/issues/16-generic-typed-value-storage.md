# Generic typed value storage

Type: prototype
Status:
Blocked by: 06, 07

## Question

Which representation for node values and undo slots preserves the four-word
static path for arbitrary typed values?

The accepted kernel and its rollback journal are integer-specialized. The public
interface carries `'a signal`, so the production kernel must store heterogeneous
values and their undo slots.

Compare the qualifying representations. Measure boxed values, unboxed integer
values, and the effect of the write barrier on a value slot. State whether the
static path stays at 4 words and stays independent of graph depth.
