# Hill-Climbing Prompt

Validate the body-read attribution mechanism with a measurement-only endpoint.

Compare normal `/echo`, which uses `Server.Body.read_all`, with `/echo_once`,
which reads one 1k chunk and responds without performing the second EOF read in
the handler path. This is a controlled probe, not a production API proposal.

If the `/echo_once` body p99 collapses and the trace shows zero EOF read returns
per stream, the previous attribution is validated: the normal `/echo` tail is
driven by extra cross-fiber body-read/EOF roundtrips after DATA is already
buffered.
