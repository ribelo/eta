#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/threads.h>
#include <caml/alloc.h>
#include <stdint.h>
#include <unistd.h>

CAMLprim value effet_blocking_release_lock_sleep(value seconds_v)
{
  double seconds = Double_val(seconds_v);
  useconds_t micros = (useconds_t)(seconds * 1000000.0);
  caml_release_runtime_system();
  usleep(micros);
  caml_acquire_runtime_system();
  return Val_unit;
}

CAMLprim value effet_blocking_hold_lock_sleep(value seconds_v)
{
  double seconds = Double_val(seconds_v);
  useconds_t micros = (useconds_t)(seconds * 1000000.0);
  usleep(micros);
  return Val_unit;
}

CAMLprim value effet_blocking_hold_lock_cpu(value iterations_v)
{
  intnat iterations = Long_val(iterations_v);
  volatile uint64_t acc = 0x12345678ULL;
  for (intnat i = 0; i < iterations; i++) {
    acc = (acc ^ (uint64_t)i) * 1103515245ULL + 12345ULL;
  }
  return Val_long((intnat)(acc & 0x3fffffff));
}

