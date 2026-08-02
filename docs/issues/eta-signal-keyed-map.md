---
kind: issue
requirements:
  - sigext-fhjg
  - sigext-z5h6
  - sigext-vha2
  - sigext-acrq
  - sigext-toyy
  - sigext-wkb7
  - sigext-6hhm
  - sigext-oqvb
  - sigext-o06w
  - sigext-pqzu
  - sigext-zlk8
  - sigext-9bch
  - sigext-ye7i
  - sigext-92o4
  - sigext-tla9
  - sigext-u1s9
  - smpkg-m1km
  - smpkg-t25w
  - smpkg-v3vp
  - smpkg-ms1p
  - smpkg-kt5y
  - smpkg-e8ac
  - smpkg-w9da
  - smpkg-x2n6
  - smpkg-1y2y
  - smmap-iyx7
  - smmap-t9g9
  - smmap-91wp
  - smmap-zdxg
  - smmap-eg8v
  - smmap-4sla
  - smmap-dq75
  - smmap-cffd
  - smmap-ikdi
  - smmap-or8f
  - smmap-bxwh
  - smmap-nn25
  - smmap-8a76
  - smmap-e4r1
  - smmap-z7kg
  - smmap-qm48
  - smmap-b81w
  - smmap-i14t
  - smmap-g2tz
  - smmap-tz92
  - smmap-aouh
  - smmap-ge5r
  - smmap-2sy9
  - smmap-hht7
  - smmap-86dk
  - smmap-2yd7
  - smmap-inyq
  - smmap-e04b
  - smmap-4d3u
  - smmap-jtck
  - smmap-mo45
  - smdiff-ij95
  - smdiff-uoix
  - smdiff-mwo3
  - smdiff-8cdy
  - smdiff-zuwx
  - smdiff-yhgb
  - smdiff-g1jq
  - smdiff-5d9x
  - smdiff-4nzq
  - smdiff-fjnq
  - smdiff-i641
  - smdiff-91zh
  - smkey-r5ns
  - smkey-suok
  - smkey-g09a
  - smkey-c4jn
  - smkey-xj6g
  - smkey-jdgk
  - smkey-4ddk
  - smkey-z4eu
  - smkey-8g9u
  - smkey-b4zb
  - smkey-9b8i
  - smkey-445b
  - smkey-69cw
  - smkey-2vhe
  - smkey-d7oa
  - smkey-vb62
  - smkey-fu6q
  - smkey-l98z
  - smkey-pqom
  - smkey-mm6e
  - smkey-6vtj
  - smkey-j9v0
  - smkey-bkjn
  - smkey-gz8v
  - smkey-x2z7
  - smtxn-8c7j
  - smtxn-yty8
  - smtxn-j5oi
  - smtxn-t2rm
  - smtxn-4wbt
  - smtxn-b12v
  - smtxn-78q6
  - smtxn-7vp7
  - smtxn-5rpo
  - smtxn-00no
  - smtxn-cdfg
  - smtxn-06z2
  - smtxn-oqx5
  - smtxn-lrob
  - smtxn-34ol
  - smtxn-ahc5
  - smtxn-d6gk
  - smdiag-y97e
  - smdiag-xfpv
  - smdiag-19k7
  - smdiag-z8s2
  - smdiag-o22x
  - smdiag-709x
  - smdiag-l4ra
  - smdiag-yqlu
  - smdiag-98i1
  - smdiag-ss8z
  - smdiag-lb9n
  - smdiag-1pr6
  - smdiag-oqvr
  - smdiag-3hlp
  - smperf-ngt2
  - smperf-g70n
  - smperf-siyo
  - smperf-mc2c
  - smperf-ssho
  - smperf-3v0d
  - smperf-mnvd
  - smperf-2vzo
---
# Eta Signal keyed map

Implement the complete
[[docs/wayfinder/eta-signal-keyed-map/map|Eta Signal keyed map design map]].

The package requirements are in these notes:

- [[docs/requirements/eta-signal/keyed-extension]]
- [[docs/requirements/eta-signal-map/README]]
- [[docs/requirements/eta-signal-map/keyed-map]]

## Wayfinder trace

| Wayfinder decisions | Requirement evidence |
|---|---|
| Product and package boundary, tickets 01–03 and 14 | `smpkg-*` |
| Balancing, kernel, API, and map laws, tickets 04–06 and 09 | `smmap-*`, `smdiff-*` |
| Private Eta Signal seam, ticket 07 | `sigext-*` |
| Keyed operator contract and structural laws, tickets 08 and 10 | `smkey-*`, `smtxn-*` |
| Change-proportional benchmark, ticket 11 | `smperf-*` |
| Keyed diagnostics, ticket 13 | `smdiag-*` |

## Implementation constraints

- Use a clean-room map implementation from the cited balancing papers.
- Do not copy Base, Core, Incremental, or `Incr_map` source.
- Use Base only as the recorded behavioral and comparison-count oracle.
- Keep Eta Crux outside this implementation ticket.

Archive this issue after every requirement has executable evidence and all
required compiler gates pass.
