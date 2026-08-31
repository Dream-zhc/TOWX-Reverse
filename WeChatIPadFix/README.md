# WeChatIPadFix

A minimal, self-contained injected dylib for the user's current target environment:

- WeChat 8.0.76
- self-signed / re-signed IPA
- HBB provides iPad login mode
- arm64

The plugin does **not** modify WeChat login state or HBB behavior. It only fixes two UI problems caused or exposed by the iPad-login setup.

## Features

1. **Edge-back + haptic feedback**
   - Reuses existing `UIScreenEdgePanGestureRecognizer` instances when available (including an existing helper tweak).
   - Only emits haptic feedback after the navigation stack depth actually decreases.
   - Cancelled gestures do not vibrate.
   - When no extra edge gesture is present, the plugin may re-enable the system interactive-pop gesture.

2. **Conversation-list position restore**
   - Captures the main Chats-tab table offset before a navigation push.
   - Does not depend on private WeChat class names.
   - On return, restores only when the same list unexpectedly jumps back to the top.
   - Uses a short 1-second repair window and never continuously locks scrolling.

3. **In-WeChat configuration page**
   - Open WeChat -> Settings.
   - An `iPad Fix` button is added to the Settings navigation bar when the Settings screen is recognized.
   - Options: edge-back, haptic strength (off/light/medium/heavy), conversation-list position fix.

## Build outputs

GitHub Actions builds and uploads:

- `WeChatIPadFix.dylib` — preferred for self-signed IPA injection
- `WeChatIPadFix.plist` — conventional tweak filter
- `WeChatIPadFix_0.1.0.deb` — conventional DEB package
- `SHA256SUMS.txt`

The dylib is built directly with Apple's iPhoneOS SDK and has no intentional dependency on CydiaSubstrate, libhooker, ElleKit, RootHide, or Theos runtime libraries.

## Validation strategy

Because a GitHub runner cannot launch WeChat 8.0.76, CI validates what can be proven offline:

- pure restore-policy unit tests;
- arm64-only Mach-O architecture;
- ad-hoc code signature verification;
- no unexpected jailbreak-hook library linkage;
- WeChat-only filter metadata;
- successful DEB pack/unpack;
- presence of the expected dylib and configuration strings.

Phone-side validation should first be done with HBB enabled and the overlapping edge-back feature in other tweaks disabled. Once this plugin is proven stable, other unrelated tweak features can be re-enabled one at a time.
