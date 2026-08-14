#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TOWXV11AvatarTapHandler)(NSUInteger index);

@interface TOWXV11AvatarView : UIView <UIScrollViewDelegate>
@property (nonatomic, copy, nullable) TOWXV11AvatarTapHandler tapHandler;
@property (nonatomic, assign, getter=isVertical) BOOL vertical;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, readonly) UIScrollView *scrollView;

- (void)applyImages:(NSArray *)images count:(NSUInteger)count selectedIndex:(NSInteger)selectedIndex animated:(BOOL)animated;
- (void)refreshLayoutPreservingOffset:(BOOL)preserveOffset;
@end

NS_ASSUME_NONNULL_END
