#pragma once
#import <UIKit/UIKit.h>

// P2A4 source uses the Swift-style `children` spelling once. UIKit's Objective-C
// API is `childViewControllers`; rewrite that token at compile time without
// touching the verified golden WeChat binary.
#define children childViewControllers
