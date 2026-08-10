# TOWX-Reverse Handoff

## Scope

This repository is the independent reverse-engineering line for TrollOpen × WeChat integration on RootHide. It must not share implementation history with `SplitWindow-RootHide-PoC`.

## Confirmed baselines

- TrollOpen 1.3.7 wxbar test: direct patch in TrollOpen's floating-window layout path can display a WeChat-only bar under the mini-window.
- WeChat 8.0.69 standalone backend: recent-contact scanning and tap-to-open chat were previously confirmed independently.
- Previous attempts to combine both sides failed because the two successful baselines had no actual IPC implementation between them.

## Current milestone: v0.1.0 probe

Only validate injection and a zero-payload cross-process round trip:

1. SpringBoard loads `TOWXSpringBoardBridge`.
2. WeChat loads `TOWXWeChatProbe`.
3. WeChat posts `WX-READY`.
4. SpringBoard posts `PING`.
5. WeChat posts `PONG`.
6. SpringBoard logs `PONG-RECV|PASS`.

No TrollOpen hook, UI, avatar decoding, recent-contact transfer, or SandyXpc is enabled yet.

## Runtime log

`/var/mobile/TrollOpenJB/bridge_probe.log`

Expected success markers:

```text
TOWX|SB|LOADED|v0.1.0
TOWX|SB|IPC-READY|DARWIN
TOWX|SB|WX-READY-RECV
TOWX|SB|PING-SEND
TOWX|SB|PONG-RECV|PASS
```

## Safety rules

- SpringBoard filter must remain `com.apple.springboard` only.
- WeChat filter must remain `com.tencent.xin` / `WeChat` only.
- Never use a broad `com.apple.UIKit` filter.
- No UIKit work in constructors.
- No synchronous IPC or image decoding inside TrollOpen `layoutSubviews`.
- SpringBoard-facing dylibs must contain arm64 and arm64e slices.
- Validate one layer at a time: injection -> ping/pong -> recentCount -> one avatar -> multiple avatars -> openRecent.

## Planned production architecture

```text
WeChat process
  scanner/cache backend
  SandyXpc server
        <->
SpringBoard process
  TOWX bridge
  TrollOpen runtime hook
  avatar bar attached to TrollOpen's animation-owned container
```

The v0.1.0 Darwin notification probe is diagnostic only; it is not the final avatar-data IPC transport.
