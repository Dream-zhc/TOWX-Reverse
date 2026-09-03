# WX Session Position Fix

Standalone WeChat session-list position fix for the current iPad-login test path.

## Scope

- Target bundle: `com.tencent.xin`
- Target test version: WeChat `8.0.76`
- Focus: **only** the session-list jump when returning from a chat.
- No side-swipe gesture or haptic implementation is included, to avoid interfering with other gesture tweaks.

## Fix strategy

The old approach of remembering only `contentOffset` is not enough on iPad-style navigation because WeChat may reload/reset the list while the chat controller is being closed.

This version records three pieces of state **before opening/leaving the list**:

1. raw `contentOffset.y`;
2. the top visible session row;
3. the session username plus the pixel delta between that row and the viewport.

When the chat controller disappears, or when the main session page reappears/reloads/resets its table offset, the plugin performs a bounded series of restore passes for about one second.

Restore priority:

1. resolve the same session again through `indexPathOfSessionUserName:`;
2. restore that row with the saved pixel delta;
3. fall back to the saved raw offset if the session cannot be resolved.

User dragging immediately cancels the restore window, so the plugin does not fight manual scrolling.

## Runtime hooks

No global `UIScrollView` hook is used.

Main page:

- `NewMainFrameViewController`
- `tableView:didSelectRowAtIndexPath:`
- `viewWillDisappear:`
- `viewWillAppear:` / `viewDidAppear:`
- optional `reloadSessions`
- optional `resetTableViewOffset:`
- optional `scrollViewWillBeginDragging:`

Chat page:

- `BaseMsgContentViewController` (fallback candidate: `MMBaseMsgContentViewController`)
- `viewDidLoad`
- `viewDidAppear:`
- `viewWillDisappear:`
- `viewDidDisappear:`

The code uses Objective-C runtime swizzling only. It does not call `MSHookMessageEx`, so the raw dylib does not require Substrate/ElleKit symbols merely to load.

## Debug log popup

On either the session list or a chat page:

**two-finger long press for 0.8 seconds**

A log alert appears with:

- detected controller/table classes;
- saved offset;
- anchor row / username;
- `reloadSessions` / `resetTableViewOffset:` events;
- every restore pass (`before -> target -> after`);
- restore counters.

Tap **复制全部** and send the full text back for the next compatibility pass.

## Test sequence

1. Inject `WXSessionPositionFix.dylib` into WeChat 8.0.76.
2. Open the Messages/session list.
3. Scroll down far enough that the top of the list is no longer visible.
4. Open any chat.
5. Return to the session list.
6. Repeat 5-10 times, including after receiving a new message if possible.
7. If it jumps, two-finger long press and copy the log immediately.

The most useful failure log contains `CAPTURE`, `CHAT viewWillDisappear`, `resetTableViewOffset`, `reloadSessions`, and `RESTORE` lines from the same return sequence.
