# H-Q2 Malicious Peer Churn Superseded Note

This lab is superseded by scratch/eta_http_research/h_q_envelope/.

The older response_header_timeout and connection_closed PASSes for header
churn and GOAWAY mid-flight measured the failure path, not the attack itself.
The canonical V-Http-Q2 record now marks both rows as DEFERRED pending
byte-level adapter hooks tracked in .backlog/Eta-h2-raw-frame-envelope.md.
