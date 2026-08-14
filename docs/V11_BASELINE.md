# TOWX V11 Smooth — Frozen Baseline

This branch starts the V11 Smooth work from the last validated TrollOpen 1.4.0 + TOWX V10 anchor test baseline.

## Source baseline

- Parent branch: `test/trollopen-1.4.0-v10-anchor`
- Parent commit: `ec80a6aafcef7b4483a4bd36a977331b30a25577`
- TrollOpen package: `com.charlieleung.trollopenjb_1.4.0_iphoneos-arm64.deb`
- TrollOpen package SHA-256: `179d7d81ee16b556d4c54124c347b253fbed4fc25167cd5cd44b68d886ec3fad`

## Golden TrollOpen 1.4.0 core hashes

These files must not be modified by V11 packaging:

```text
TrollOpenJB.dylib
65d1c2898053417629b05af663b0e99cf9eb71fcc83037bf8c9685cc746c015c

TrollOpenCamera.dylib
c1dfc7b99ae551a6be9eb1f93d138a7a270e87df9b3bfde9b7f096e3737626ae

TrollOpenKeyboard.dylib
7986a9ef69d98fcf7db9e3a0a8ab80cc3b652bfbce6e07a90ba9224d44756fdd
```

## Development order

1. Session Controller
2. Window Follower
3. Placement Engine
4. Native Scroll / Touch
5. Interruptible Animation
6. WeChat Session Gate
7. Avatar IO / Decode
8. Retire V10 legacy polling/frame-cache paths
9. Full regression
10. RC package

## Stability rules

- One functional phase per commit.
- Build and device-test every phase before advancing.
- Do not modify the three TrollOpen 1.4.0 core dylibs.
- Do not use polling to hide lifecycle defects.
- Do not perform IO or hierarchy scans inside the future display-link follower.
- If a phase regresses SpringBoard or TrollOpen behavior, revert to the last accepted commit before continuing.
