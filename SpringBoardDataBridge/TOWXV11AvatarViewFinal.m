#import "TOWXV11AvatarView.h"
#import "TOWXV11Diagnostics.h"

static const NSUInteger kTOWXV11MaxAvatars = 6;

@interface TOWXV11AvatarCellFinal : UIControl
@property (nonatomic, readonly) UIImageView *imageView;
@property (nonatomic, assign) NSUInteger avatarIndex;
@property (nonatomic, strong) UIViewPropertyAnimator *pressAnimator;
- (void)applyImage:(nullable UIImage *)image selected:(BOOL)selected animated:(BOOL)animated;
@end

@implementation TOWXV11AvatarCellFinal {
    UIImageView *_imageView;
}
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.clipsToBounds = NO;
    self.backgroundColor = UIColor.clearColor;
    _imageView = [[UIImageView alloc] initWithFrame:self.bounds];
    _imageView.userInteractionEnabled = NO;
    _imageView.clipsToBounds = YES;
    _imageView.contentMode = UIViewContentModeScaleAspectFill;
    _imageView.backgroundColor = UIColor.secondarySystemFillColor;
    [self addSubview:_imageView];
    return self;
}
- (UIImageView *)imageView { return _imageView; }
- (void)layoutSubviews {
    [super layoutSubviews];
    _imageView.frame = CGRectInset(self.bounds, 2.0, 2.0);
    _imageView.layer.cornerRadius = CGRectGetWidth(_imageView.bounds) * 0.5;
    self.layer.cornerRadius = CGRectGetWidth(self.bounds) * 0.5;
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self.pressAnimator stopAnimation:YES];
    __weak typeof(self) weakSelf = self;
    UIViewPropertyAnimator *animator = nil;
    if (highlighted) {
        animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.07 curve:UIViewAnimationCurveEaseOut animations:^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self) self.transform = CGAffineTransformMakeScale(0.94, 0.94);
        }];
    } else {
        UISpringTimingParameters *timing = [[UISpringTimingParameters alloc] initWithDampingRatio:0.80];
        animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.18 timingParameters:timing];
        [animator addAnimations:^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self) self.transform = CGAffineTransformIdentity;
        }];
    }
    [animator addCompletion:^(__unused UIViewAnimatingPosition position) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self.pressAnimator == animator) self.pressAnimator = nil;
    }];
    self.pressAnimator = animator;
    [animator startAnimation];
}
- (void)applyImage:(UIImage *)image selected:(BOOL)selected animated:(BOOL)animated {
    UIImage *display = image ?: [UIImage systemImageNamed:@"person.crop.circle.fill"];
    _imageView.image = display;
    _imageView.contentMode = image ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;
    _imageView.tintColor = image ? nil : UIColor.tertiaryLabelColor;
    _imageView.alpha = image ? 1.0 : 0.55;
    void (^changes)(void) = ^{
        self.layer.borderWidth = selected ? 2.4 : 0.8;
        self.layer.borderColor = (selected ? UIColor.systemGreenColor : [UIColor colorWithWhite:0.72 alpha:0.55]).CGColor;
        if (!self.highlighted) self.transform = selected ? CGAffineTransformMakeScale(1.025, 1.025) : CGAffineTransformIdentity;
    };
    if (!animated) { changes(); return; }
    UISpringTimingParameters *timing = [[UISpringTimingParameters alloc] initWithDampingRatio:0.86];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.18 timingParameters:timing];
    [animator addAnimations:changes];
    [animator startAnimation];
}
@end

@interface TOWXV11AvatarView ()
@property (nonatomic, strong) UIScrollView *internalScrollView;
@property (nonatomic, strong) NSArray<TOWXV11AvatarCellFinal *> *cells;
@property (nonatomic, assign) NSUInteger avatarCount;
@property (nonatomic, strong) NSArray *currentImages;
@property (nonatomic, assign) BOOL layoutPending;
@end

@implementation TOWXV11AvatarView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.clipsToBounds = NO;
    _selectedIndex = NSNotFound;
    _internalScrollView = [[UIScrollView alloc] initWithFrame:self.bounds];
    _internalScrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _internalScrollView.backgroundColor = UIColor.clearColor;
    _internalScrollView.opaque = NO;
    _internalScrollView.clipsToBounds = YES;
    _internalScrollView.showsHorizontalScrollIndicator = NO;
    _internalScrollView.showsVerticalScrollIndicator = NO;
    _internalScrollView.directionalLockEnabled = YES;
    _internalScrollView.delaysContentTouches = NO;
    _internalScrollView.canCancelContentTouches = YES;
    _internalScrollView.bounces = YES;
    _internalScrollView.decelerationRate = UIScrollViewDecelerationRateNormal;
    _internalScrollView.scrollsToTop = NO;
    if (@available(iOS 11.0, *)) _internalScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _internalScrollView.delegate = self;
    [self addSubview:_internalScrollView];
    NSMutableArray *cells = [NSMutableArray arrayWithCapacity:kTOWXV11MaxAvatars];
    for (NSUInteger i = 0; i < kTOWXV11MaxAvatars; i++) {
        TOWXV11AvatarCellFinal *cell = [[TOWXV11AvatarCellFinal alloc] initWithFrame:CGRectZero];
        cell.avatarIndex = i;
        cell.hidden = YES;
        [cell addTarget:self action:@selector(cellTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_internalScrollView addSubview:cell];
        [cells addObject:cell];
    }
    _cells = cells;
    _currentImages = @[];
    TOWXV11DiagLog("AVATAR", "VIEW-CREATE|physics=native|bounce=on|cells=%lu", (unsigned long)kTOWXV11MaxAvatars);
    return self;
}
- (UIScrollView *)scrollView { return self.internalScrollView; }
- (void)setVertical:(BOOL)vertical {
    if (_vertical == vertical) return;
    _vertical = vertical;
    self.internalScrollView.contentOffset = CGPointZero;
    [self refreshLayoutPreservingOffset:NO];
    TOWXV11DiagLog("AVATAR", "AXIS|value=%s", vertical ? "vertical" : "horizontal");
}
- (void)setSelectedIndex:(NSInteger)selectedIndex { _selectedIndex = selectedIndex; [self updateCellsAnimated:YES]; }
- (void)applyImages:(NSArray *)images count:(NSUInteger)count selectedIndex:(NSInteger)selectedIndex animated:(BOOL)animated {
    self.currentImages = images ?: @[];
    self.avatarCount = MIN(count, kTOWXV11MaxAvatars);
    _selectedIndex = selectedIndex;
    [self updateCellsAnimated:animated];
    [self refreshLayoutPreservingOffset:YES];
}
- (void)updateCellsAnimated:(BOOL)animated {
    for (NSUInteger i = 0; i < self.cells.count; i++) {
        TOWXV11AvatarCellFinal *cell = self.cells[i];
        BOOL available = i < self.avatarCount;
        cell.hidden = !available;
        cell.userInteractionEnabled = available;
        if (!available) continue;
        id value = i < self.currentImages.count ? self.currentImages[i] : nil;
        UIImage *image = [value isKindOfClass:[UIImage class]] ? value : nil;
        [cell applyImage:image selected:(_selectedIndex == (NSInteger)i) animated:animated];
    }
}
- (void)layoutSubviews { [super layoutSubviews]; self.internalScrollView.frame = self.bounds; [self refreshLayoutPreservingOffset:YES]; }
- (void)refreshLayoutPreservingOffset:(BOOL)preserveOffset {
    UIScrollView *scroll = self.internalScrollView;
    if (scroll.tracking || scroll.dragging || scroll.decelerating) { self.layoutPending = YES; return; }
    self.layoutPending = NO;
    CGFloat width = CGRectGetWidth(self.bounds), height = CGRectGetHeight(self.bounds);
    if (width < 2.0 || height < 2.0) return;
    CGFloat diameter = MIN(52.0, MAX(42.0, (self.vertical ? width : height) - 10.0));
    CGFloat spacing = 10.0, padding = 6.0;
    CGFloat total = self.avatarCount ? diameter * self.avatarCount + spacing * (self.avatarCount - 1) : 0.0;
    CGFloat viewportLength = self.vertical ? height : width;
    CGFloat contentLength = MAX(viewportLength, total + padding * 2.0);
    CGFloat start = total <= viewportLength - padding * 2.0 ? floor((viewportLength - total) * 0.5) : padding;
    CGPoint oldOffset = scroll.contentOffset;
    if (self.vertical) {
        scroll.contentSize = CGSizeMake(width, contentLength);
        scroll.alwaysBounceVertical = contentLength > height + 0.5;
        scroll.alwaysBounceHorizontal = NO;
        for (NSUInteger i = 0; i < self.avatarCount; i++) self.cells[i].frame = CGRectMake(floor((width - diameter) * 0.5), start + i * (diameter + spacing), diameter, diameter);
    } else {
        scroll.contentSize = CGSizeMake(contentLength, height);
        scroll.alwaysBounceHorizontal = contentLength > width + 0.5;
        scroll.alwaysBounceVertical = NO;
        for (NSUInteger i = 0; i < self.avatarCount; i++) self.cells[i].frame = CGRectMake(start + i * (diameter + spacing), floor((height - diameter) * 0.5), diameter, diameter);
    }
    if (preserveOffset) {
        CGFloat maxX = MAX(0.0, scroll.contentSize.width - width), maxY = MAX(0.0, scroll.contentSize.height - height);
        scroll.contentOffset = CGPointMake(MIN(MAX(oldOffset.x, 0.0), maxX), MIN(MAX(oldOffset.y, 0.0), maxY));
    } else scroll.contentOffset = CGPointZero;
}
- (void)cellTapped:(TOWXV11AvatarCellFinal *)cell {
    if (cell.avatarIndex >= self.avatarCount) return;
    TOWXV11DiagLog("AVATAR", "TAP|index=%lu|axis=%s", (unsigned long)cell.avatarIndex, self.vertical ? "vertical" : "horizontal");
    if (self.tapHandler) self.tapHandler(cell.avatarIndex);
}
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView { TOWXV11DiagLog("AVATAR", "SCROLL-BEGIN|axis=%s|offset={%.2f,%.2f}", self.vertical ? "vertical" : "horizontal", scrollView.contentOffset.x, scrollView.contentOffset.y); }
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    TOWXV11DiagLog("AVATAR", "SCROLL-DRAG-END|decelerate=%d|offset={%.2f,%.2f}", decelerate ? 1 : 0, scrollView.contentOffset.x, scrollView.contentOffset.y);
    if (!decelerate && self.layoutPending) [self refreshLayoutPreservingOffset:YES];
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    TOWXV11DiagLog("AVATAR", "SCROLL-END|offset={%.2f,%.2f}", scrollView.contentOffset.x, scrollView.contentOffset.y);
    if (self.layoutPending) [self refreshLayoutPreservingOffset:YES];
}
@end

__attribute__((constructor)) static void TOWXV11AvatarViewFinalMarker(void) {
    TOWXV11DiagLog("AVATAR", "LOADED|Smooth1-S4|native-scroll+uicontrol+weak-animator");
}
