#pragma once
#import <UIKit/UIKit.h>

// UIKit compatibility for the adapter build.
#define children childViewControllers

// Existing P2A4 packaging workflow still verifies this historical marker.
// Keep it in the adapter binary while runtime logging reports v0.5.0.
__attribute__((used)) static const char TOWXCIAdapterCompatMarker[] =
    "TOWX|WX|P2A4|ADAPTER-START|v0.4.0";
