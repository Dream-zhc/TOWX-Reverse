# TOWX Reverse — Phase 2A

Phase 2A validates the first real recent-contact avatar from WeChat without changing TrollOpen's existing floating-window behavior.

## Deliverables

- `TOWX-WeChatBackend-8.0.69-P2A.deb`: injects only into WeChat, scans the main Chats tab, caches up to six visible recent rows, and transports avatar 0 through Darwin notify state for validation. It creates no in-app UI.
- `TrollOpen-1.3.7-wxbar1-TOWX-P2A.deb`: exact wxbar1 TrollOpen baseline plus a separate SpringBoard data receiver. The workflow verifies that `TrollOpenJB.dylib` keeps SHA-256 `5bac29748b81bc07131f8c641a41f4a102a3b2e9cb8447007b753716369ef802`.

## Test

1. Remove the old `com.dream.towxreverse.probe` test package and old standalone WeChat debug tweak if still installed.
2. Install both Phase 2A DEBs.
3. Respring.
4. Open WeChat on the first (Chats) tab and leave the recent list visible for a few seconds.
5. Read `/var/mobile/TrollOpenJB/phase2a.log` from rootfs.

Expected:

```
TOWX|SB|P2A|LOADED|v0.2.0
TOWX|SB|P2A|READY-LISTENER
TOWX|SB|P2A|AVATAR0-PASS|generation=...|count=...|bytes=...|hash=...|file=/var/mobile/TrollOpenJB/avatar0-p2a.jpg
```

`avatar0-p2a.jpg` is the exact 24/32px thumbnail reconstructed by SpringBoard and can be inspected to confirm it is the first recent WeChat contact avatar.
