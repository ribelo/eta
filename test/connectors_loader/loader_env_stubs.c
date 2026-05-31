#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <stdlib.h>

CAMLprim value eta_test_unsetenv(value v_name)
{
  CAMLparam1(v_name);
  (void)unsetenv(String_val(v_name));
  CAMLreturn(Val_unit);
}
