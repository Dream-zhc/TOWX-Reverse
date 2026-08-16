#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_required(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"required pattern missing in {path}: {old!r}")
    path.write_text(text.replace(old, new), encoding="utf-8")


# SpringBoard data plane: 30 remote slots / 30 open indexes.
data = ROOT / "SpringBoardDataBridge" / "TOWXV11DataControllerFix3.m"
replace_required(data, "#define TOWXV11_MAX_RECENTS_FIX3 15U", "#define TOWXV11_MAX_RECENTS_FIX3 30U")
replace_required(data, 'LOADED|Smooth1-FIX3|15-recents+background-imageio', 'LOADED|Companion141-30|30-recents+background-imageio')
replace_required(data, 'LISTENERS|fix=3|ready=%u|ack=%u|max=15', 'LISTENERS|companion=30|ready=%u|ack=%u|max=30')

# Avatar UI: create 30 reusable cells; viewport still only shows complete slots and scrolls natively.
avatar = ROOT / "SpringBoardDataBridge" / "TOWXV11AvatarViewFix3.m"
replace_required(avatar, "static const NSUInteger kTOWXV11MaxAvatarsFix3 = 15;", "static const NSUInteger kTOWXV11MaxAvatarsFix3 = 30;")
replace_required(avatar, 'LOADED|Smooth1-FIX5|15-cells+44pt+integer-visible-slots+8pt-visual-gap+smooth-scroll', 'LOADED|Companion141-30|30-cells+44pt+integer-visible-slots+8pt-visual-gap+smooth-scroll')

# Landscape anchor selection: real TrollOpen phone-style card is tall/narrow. The old scorer
# preferred ~40% screen area and could choose a much wider outer presentation container.
follower = ROOT / "SpringBoardDataBridge" / "TOWXV11WindowFollowerFix3.m"
replace_required(follower,
                 "CGFloat targetArea = landscape ? 0.40 : 0.42;",
                 "CGFloat targetArea = landscape ? 0.21 : 0.42;")
old_block = '''    if (landscape) {\n        if (wr >= 0.12 && wr <= 0.58 && hr >= 0.48) score += 240.0;\n        if (hr >= 0.85 && hr <= 1.10 && wr <= 0.58) score += 150.0;\n        if (wr > 0.70) score -= 260.0;\n    } else {\n'''
new_block = '''    if (landscape) {\n        /* Phone-style floating card in landscape: tall, narrow, rounded. Prefer the real card\n           over the much wider scene/presentation host that previously pushed the rail to center. */\n        if (wr >= 0.14 && wr <= 0.38 && hr >= 0.70) score += 560.0;\n        if (hr >= 0.86 && hr <= 1.12 && wr <= 0.42) score += 240.0;\n        if (corner >= 12.0 && wr <= 0.44) score += 210.0;\n        if (wr > 0.46) score -= 520.0;\n        if (wr > 0.60) score -= 520.0;\n    } else {\n'''
replace_required(follower, old_block, new_block)
replace_required(follower,
                 'LOADED|Smooth1-FIX5|screen-coordinate-space+landscape-fullheight-card+presentation+displaylink',
                 'LOADED|Companion141-30|landscape-narrow-card-priority+presentation+displaylink')

# V13 uses the nil-coalescing expression as a receiver. Objective-C needs parentheses around
# that expression; otherwise clang interprets the doubled '[' as a nested message expression.
wechat = ROOT / "WeChatGoldenAdapter" / "TOWXGoldenAdapterV13Thirty.m"
replace_required(wechat,
                 '        if ([[TOWXTitleFromCell(cell) ?: @""] isEqualToString:target]) return path;',
                 '        NSString *visibleTitle = TOWXTitleFromCell(cell) ?: @"";\n        if ([visibleTitle isEqualToString:target]) return path;')

print("Prepared TOWX Companion 1.4.1 / 30-recents sources")
