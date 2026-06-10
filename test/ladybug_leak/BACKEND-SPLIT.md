# Backend Split

`test/ladybug_leak` remains a native mock-library integration suite. It sets a
process-wide `ETA_LADYBUG_LIBRARY` before the one-shot Ladybug loader runs,
uses `ladybug_mock_lib.c`, and verifies native query-result cleanup, close
coordination, and timeout behavior through mock state files.

Those tests depend on a C mock library, environment state, and native handle
lifetime, so they are deliberately not functorized across runtime backends.
