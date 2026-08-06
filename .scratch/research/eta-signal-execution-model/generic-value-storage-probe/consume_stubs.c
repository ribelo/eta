#include <caml/mlvalues.h>

CAMLprim value eta_signal_consume_box(value boxed)
{
  __asm__ __volatile__("" : : "r"(boxed) : "memory");
  return Val_unit;
}
