#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <unistd.h>

CAMLprim value effet_test_hold_lock_sleep(value seconds)
{
  CAMLparam1(seconds);
  double secs = Double_val(seconds);
  if (secs > 0.0) {
    usleep((useconds_t)(secs * 1000000.0));
  }
  CAMLreturn(Val_unit);
}
