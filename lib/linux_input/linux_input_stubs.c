#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>

#if defined(__linux__)
#include <errno.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static int eta_fd(value fd_v) { return Int_val(fd_v); }

CAMLprim value eta_linux_input_device_name(value fd_v) {
  CAMLparam1(fd_v);
  char name[256];
  int rc = ioctl(eta_fd(fd_v), EVIOCGNAME(sizeof(name)), name);
  if (rc < 0) uerror("ioctl(EVIOCGNAME)", Nothing);
  name[sizeof(name) - 1] = '\0';
  CAMLreturn(caml_copy_string(name));
}

CAMLprim value eta_linux_input_device_ids(value fd_v) {
  CAMLparam1(fd_v);
  CAMLlocal1(result);
  struct input_id id;
  memset(&id, 0, sizeof(id));
  if (ioctl(eta_fd(fd_v), EVIOCGID, &id) < 0) uerror("ioctl(EVIOCGID)", Nothing);
  result = caml_alloc_tuple(4);
  Store_field(result, 0, Val_int(id.bustype));
  Store_field(result, 1, Val_int(id.vendor));
  Store_field(result, 2, Val_int(id.product));
  Store_field(result, 3, Val_int(id.version));
  CAMLreturn(result);
}

CAMLprim value eta_linux_input_abs_info(value fd_v, value code_v) {
  CAMLparam2(fd_v, code_v);
  CAMLlocal1(result);
  struct input_absinfo info;
  memset(&info, 0, sizeof(info));
  if (ioctl(eta_fd(fd_v), EVIOCGABS(Int_val(code_v)), &info) < 0)
    uerror("ioctl(EVIOCGABS)", Nothing);
  result = caml_alloc_tuple(6);
  Store_field(result, 0, Val_int(info.value));
  Store_field(result, 1, Val_int(info.minimum));
  Store_field(result, 2, Val_int(info.maximum));
  Store_field(result, 3, Val_int(info.fuzz));
  Store_field(result, 4, Val_int(info.flat));
  Store_field(result, 5, Val_int(info.resolution));
  CAMLreturn(result);
}

CAMLprim value eta_linux_input_grab(value fd_v, value enabled_v) {
  CAMLparam2(fd_v, enabled_v);
  void *arg = Bool_val(enabled_v) ? (void *)1 : (void *)0;
  if (ioctl(eta_fd(fd_v), EVIOCGRAB, arg) < 0) uerror("ioctl(EVIOCGRAB)", Nothing);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_linux_input_read_event(value fd_v) {
  CAMLparam1(fd_v);
  CAMLlocal1(result);
  struct input_event ev;
  ssize_t n;
  int saved_errno = 0;
  int fd = eta_fd(fd_v);

  caml_enter_blocking_section();
  do {
    n = read(fd, &ev, sizeof(ev));
  } while (n < 0 && errno == EINTR);
  if (n < 0) saved_errno = errno;
  caml_leave_blocking_section();

  if (n < 0) {
    errno = saved_errno;
    uerror("read", Nothing);
  }
  if (n == 0) caml_raise_end_of_file();
  if ((size_t)n != sizeof(ev)) caml_failwith("short evdev read");

  result = caml_alloc_tuple(5);
  Store_field(result, 0, caml_copy_int64((int64_t)ev.input_event_sec));
  Store_field(result, 1, caml_copy_int64((int64_t)ev.input_event_usec));
  Store_field(result, 2, Val_int(ev.type));
  Store_field(result, 3, Val_int(ev.code));
  Store_field(result, 4, Val_int(ev.value));
  CAMLreturn(result);
}

CAMLprim value eta_linux_input_uinput_set_evbit(value fd_v, value bit_v) {
  CAMLparam2(fd_v, bit_v);
  if (ioctl(eta_fd(fd_v), UI_SET_EVBIT, Int_val(bit_v)) < 0)
    uerror("ioctl(UI_SET_EVBIT)", Nothing);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_linux_input_uinput_set_keybit(value fd_v, value bit_v) {
  CAMLparam2(fd_v, bit_v);
  if (ioctl(eta_fd(fd_v), UI_SET_KEYBIT, Int_val(bit_v)) < 0)
    uerror("ioctl(UI_SET_KEYBIT)", Nothing);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_linux_input_uinput_set_relbit(value fd_v, value bit_v) {
  CAMLparam2(fd_v, bit_v);
  if (ioctl(eta_fd(fd_v), UI_SET_RELBIT, Int_val(bit_v)) < 0)
    uerror("ioctl(UI_SET_RELBIT)", Nothing);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_linux_input_uinput_setup(value fd_v, value name_v, value ids_v) {
  CAMLparam3(fd_v, name_v, ids_v);
  struct uinput_setup setup;
  memset(&setup, 0, sizeof(setup));
  snprintf(setup.name, UINPUT_MAX_NAME_SIZE, "%s", String_val(name_v));
  setup.id.bustype = Int_val(Field(ids_v, 0));
  setup.id.vendor = Int_val(Field(ids_v, 1));
  setup.id.product = Int_val(Field(ids_v, 2));
  setup.id.version = Int_val(Field(ids_v, 3));
  if (ioctl(eta_fd(fd_v), UI_DEV_SETUP, &setup) < 0)
    uerror("ioctl(UI_DEV_SETUP)", Nothing);
  if (ioctl(eta_fd(fd_v), UI_DEV_CREATE) < 0)
    uerror("ioctl(UI_DEV_CREATE)", Nothing);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_linux_input_uinput_destroy(value fd_v) {
  CAMLparam1(fd_v);
  if (ioctl(eta_fd(fd_v), UI_DEV_DESTROY) < 0)
    uerror("ioctl(UI_DEV_DESTROY)", Nothing);
  CAMLreturn(Val_unit);
}

CAMLprim value eta_linux_input_write_event(value fd_v, value type_v, value code_v,
                                          value event_value_v) {
  CAMLparam4(fd_v, type_v, code_v, event_value_v);
  struct input_event ev;
  ssize_t n;
  int saved_errno = 0;
  int fd = eta_fd(fd_v);
  memset(&ev, 0, sizeof(ev));
  ev.type = Int_val(type_v);
  ev.code = Int_val(code_v);
  ev.value = Int_val(event_value_v);

  caml_enter_blocking_section();
  do {
    n = write(fd, &ev, sizeof(ev));
  } while (n < 0 && errno == EINTR);
  if (n < 0) saved_errno = errno;
  caml_leave_blocking_section();

  if (n < 0) {
    errno = saved_errno;
    uerror("write", Nothing);
  }
  if ((size_t)n != sizeof(ev)) caml_failwith("short uinput write");
  CAMLreturn(Val_unit);
}

#else

static void eta_linux_input_unsupported(void) {
  caml_failwith("eta_linux_input requires Linux evdev/uinput support");
}

CAMLprim value eta_linux_input_device_name(value fd_v) {
  CAMLparam1(fd_v);
  eta_linux_input_unsupported();
  CAMLreturn(Val_unit);
}

CAMLprim value eta_linux_input_device_ids(value fd_v) {
  CAMLparam1(fd_v);
  eta_linux_input_unsupported();
  CAMLreturn(Val_unit);
}

CAMLprim value eta_linux_input_abs_info(value fd_v, value code_v) {
  CAMLparam2(fd_v, code_v);
  eta_linux_input_unsupported();
  CAMLreturn(Val_unit);
}

CAMLprim value eta_linux_input_grab(value fd_v, value enabled_v) {
  CAMLparam2(fd_v, enabled_v);
  eta_linux_input_unsupported();
  CAMLreturn(Val_unit);
}

CAMLprim value eta_linux_input_read_event(value fd_v) {
  CAMLparam1(fd_v);
  eta_linux_input_unsupported();
  CAMLreturn(Val_unit);
}

CAMLprim value eta_linux_input_uinput_set_evbit(value fd_v, value bit_v) {
  CAMLparam2(fd_v, bit_v);
  eta_linux_input_unsupported();
  CAMLreturn(Val_unit);
}

CAMLprim value eta_linux_input_uinput_set_keybit(value fd_v, value bit_v) {
  CAMLparam2(fd_v, bit_v);
  eta_linux_input_unsupported();
  CAMLreturn(Val_unit);
}

CAMLprim value eta_linux_input_uinput_set_relbit(value fd_v, value bit_v) {
  CAMLparam2(fd_v, bit_v);
  eta_linux_input_unsupported();
  CAMLreturn(Val_unit);
}

CAMLprim value eta_linux_input_uinput_setup(value fd_v, value name_v, value ids_v) {
  CAMLparam3(fd_v, name_v, ids_v);
  eta_linux_input_unsupported();
  CAMLreturn(Val_unit);
}

CAMLprim value eta_linux_input_uinput_destroy(value fd_v) {
  CAMLparam1(fd_v);
  eta_linux_input_unsupported();
  CAMLreturn(Val_unit);
}

CAMLprim value eta_linux_input_write_event(value fd_v, value type_v, value code_v,
                                          value event_value_v) {
  CAMLparam4(fd_v, type_v, code_v, event_value_v);
  eta_linux_input_unsupported();
  CAMLreturn(Val_unit);
}

#endif
