# WeChatIPadFix

Target environment:

- WeChat 8.0.76
- self-signed / re-signed IPA
- HBB provides iPad login mode
- arm64

The plugin does not modify login state or HBB behavior.

## 0.2.0: conversation-list repair redesign

The 0.1.x implementation assumed a standard `UINavigationController` push/pop lifecycle. That assumption is not reliable for WeChat 8.0.76 and HBB iPad mode, so 0.2.0 removes the conversation repair from navigation lifecycle hooks completely.

The new repair works as a window-level monitor:

1. While the Chats tab is visible, locate the most likely conversation `UITableView` from the live window hierarchy.
2. Continuously remember its real `contentOffset` while the user is on the list.
3. When the conversation list leaves the screen, arm one return repair using the last valid offset.
4. When the list reappears (including when WeChat/HBB rebuilds the table), open a short 3-second repair window.
5. If the list is unexpectedly at the top, restore the saved offset. Repeated resets inside the window are repaired again.
6. If the user starts dragging manually, stop repairing immediately. Switching to another bottom tab also does not trigger a repair.

This avoids relying on private WeChat class names, `pushViewController:`, or a specific view-controller instance surviving the chat transition.

## Live in-app diagnostics

Open WeChat -> Settings -> `iPad Fix`.

The configuration page now shows:

- conversation list detected / not detected;
- current bottom-tab state;
- last saved offset;
- current offset;
- repair state (`recording`, `waiting for return`, `repair window`);
- successful repair count;
- raw restore-write count;
- detected table class and owning view-controller class;
- last repair event.

This is intentionally included because a GitHub runner cannot observe the real HBB/WeChat runtime. A phone-side test can therefore identify exactly which stage fails without requiring system logs.

## Other features

- Edge-back helper remains available but is independent of the list repair.
- Haptic strength can still be configured; it is not required for the conversation-list fix.

## Build outputs

GitHub Actions builds and uploads:

- `WeChatIPadFix.dylib` — preferred for self-signed IPA injection
- `WeChatIPadFix.plist`
- `WeChatIPadFix_0.2.0.deb`
- `SHA256SUMS.txt`

The dylib is built directly with Apple's iPhoneOS SDK and has no intentional dependency on CydiaSubstrate, libhooker, ElleKit, RootHide, or Theos runtime libraries.
