# WeChatIPadFix

Target environment:

- WeChat 8.0.76
- self-signed / re-signed IPA
- HBB provides iPad login mode
- arm64

The plugin does not modify the login state or HBB itself.

## 0.3.0: target WeChat's real main conversation controller

The 0.1 implementation assumed normal push/pop lifecycle. The 0.2 implementation scanned window-level UITableViews and tried to repair contentOffset after the fact. Phone testing showed neither path affects the HBB iPad-mode jump-to-top bug.

0.3 removes the generic table monitor. It targets the WeChat main conversation controller directly:

1. Prefer `NewMainFrameViewController` when it exists at runtime.
2. If the name changed, score UIViewController classes containing MainFrame / Session / Conversation traits, `m_tableView`, `tableView:didSelectRowAtIndexPath:` and reload-session methods.
3. Resolve the controller's real `m_tableView` (with a controller-local table fallback only).
4. Save its offset in the real chat-selection callback before entering a chat.
5. Hook no-argument methods whose selector contains `reloadSession`.
6. During the short return window, protect only that exact main table from `setContentOffset(top)` and `scrollToRow(section=0,row=0)`.
7. Hook the main table's `reloadData` path and perform repeated restores after layout/reload.
8. End protection after the real main controller returns and the short protection window becomes stable.

Global UIKit hooks are installed only as interception points and are gated by pointer identity to the resolved main conversation table. Other WeChat tables are not modified.

## In-app diagnostics

Open WeChat -> Settings -> `iPad Fix`.

0.3 reports:

- targeted main-frame class;
- target-hook installation status;
- saved and current main-table offsets;
- repair state;
- `reloadSession*` and table `reloadData` counts;
- blocked top `setContentOffset` count;
- blocked `scrollToRow(0,0)` count;
- restore-write / success counts;
- resolved main-table and owner class;
- runtime candidate classes;
- last repair event.

This makes a phone-side failure actionable even without external logs: if the main-frame class is not resolved we know discovery failed; if reload counters change we know the WeChat-internal refresh path is active; if top-scroll counters change we know the actual jump request has been intercepted.

## Other features

- Edge-back helper and configurable haptics remain available but are independent of the conversation-list repair.

## Build outputs

GitHub Actions uploads:

- `WeChatIPadFix.dylib`
- `WeChatIPadFix.plist`
- `WeChatIPadFix_0.3.0.deb`
- `SHA256SUMS.txt`

The dylib is built directly against Apple's iPhoneOS SDK with no intentional dependency on CydiaSubstrate, libhooker, ElleKit or RootHide runtime libraries.
