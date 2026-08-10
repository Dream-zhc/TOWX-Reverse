# TOWX-Reverse

Independent RootHide reverse-engineering project for TrollOpen × WeChat integration.

This repository is intentionally separate from `SplitWindow-RootHide-PoC`.

## Current milestone

`v0.1.0-probe` validates only process injection and cross-process Darwin notification ping/pong:

- SpringBoard probe loads.
- WeChat probe loads.
- SpringBoard receives `WX-READY`.
- SpringBoard sends `PING`.
- WeChat responds `PONG`.
- SpringBoard records `PASS`.

No TrollOpen UI hooks, avatar scanning, SandyXpc, or recent-contact data transfer are enabled in this milestone.

## Runtime log

After installing, respring, launch WeChat once, then inspect:

```sh
cat /var/mobile/TrollOpenJB/bridge_probe.log
```

Expected success sequence includes:

```text
TOWX|SB|LOADED|v0.1.0
TOWX|SB|IPC-READY|DARWIN
TOWX|SB|WX-READY-RECV
TOWX|SB|PING-SEND
TOWX|SB|PONG-RECV|PASS
```
