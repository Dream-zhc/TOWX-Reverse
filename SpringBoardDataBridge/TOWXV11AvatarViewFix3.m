#import "TOWXV11AvatarView.h"
#import "TOWXV11Diagnostics.h"

static const NSUInteger kTOWXV11MaxAvatarsFix3 = 15;
static const CGFloat kTOWXV11AvatarDiameterFix3 = 44.0;
static const CGFloat kTOWXV11SpacingFix3 = 7.0;
static const CGFloat kTOWXV11PaddingFix3 = 5.0;
static const CGFloat kTOWXV11EdgeShieldFix3 = 7.0;
static const CGFloat kTOWXV11VisualGapFix3 = 5.0;

@interface TOWXV11AvatarScrollViewFix3 : UIScrollView
@end
@implementation TOWXV11AvatarScrollViewFix3
- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    (void)view;
    return YES;
}
@end

@interface TOWXV11AvatarCellFix3 : UIControl
@property (nonatomic, readonly) UIImageView *imageView;
@property (nonatomic, assign) NSUInteger avatarIndex;
- (void)applyImage:(nullable UIImage *)image selected:(BOOL)selected animated:(BOOL)animated;
@end

@implementation TOWXV11AvatarCellFix3 {
    UIImageView *_imageView;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.exclusiveTouch = YES;
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
    _imageView.frame = CGRectInset(self.bounds, 1.7, 1.7);
    _imageView.layer.cornerRadius = CGRectGetWidth(_imageView.bounds) * 0.5;
    self.layer.cornerRadius = CGRectGetWidth(self.bounds) * 0.5;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:highlighted ? 0.055 : 0.17
                          delay:0.0
         usingSpringWithDamping:highlighted ? 1.0 : 0.84
          initialSpringVelocity:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.95, 0.95) : CGAffineTransformIdentity;
    } completion:nil];
}

- (void)applyImage:(UIImage *)image selected:(BOOL)selected animated:(BOOL)animated {
    UIImage *display = image ?: [UIImage systemImageNamed:@"person.crop.circle.fill"];
    _imageView.image = display;
    _imageView.contentMode = image ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;
    _imageView.tintColor = image ? nil : UIColor.tertiaryLabelColor;
    _imageView.alpha = image ? 1.0 : 0.55;

    void (^changes)(void) = ^{
        self.layer.borderWidth = selected ? 2.1 : 0.75;
        self.layer.borderColor = (selected ? UIColor.systemGreenColor : [UIColor colorWithWhite:0.72 alpha:0.55]).CGColor;
    };
    if (!animated) {
        changes();
    } else {
        [UIView animateWithDuration:0.16
                              delay:0.0
             usingSpringWithDamping:0.88
              initialSpringVelocity:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:changes completion:nil];
    }
}
@end

@interface TOWXV11AvatarView ()
@property (nonatomic, strong) TOWXV11AvatarScrollViewFix3 *internalScrollView;
@property (nonatomic, strong) NSArray<TOWXV11AvatarCellFix3 *> *cells;
@property (nonatomic, assign) NSUInteger avatarCount;
@property (nonatomic, strong) NSArray *currentImages;
@property (nonatomic, assign) BOOL layoutPending;
@property (nonatomic, assign) CGFloat lastLoggedRange;
@property (nonatomic, assign) BOOL lastLoggedVertical;
@property (nonatomic, assign) NSUInteger lastLoggedCount;
@end

@implementation TOWXV11AvatarView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.clipsToBounds = NO;
    _selectedIndex = NSNotFound;
    _lastLoggedRange = -1.0;
    _lastLoggedCount = NSNotFound;

    _internalScrollView = [[TOWXV11AvatarScrollViewFix3 alloc] initWithFrame:self.bounds];
    _internalScrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _internalScrollView.backgroundColor = UIColor.clearColor;
    _internalScrollView.opaque = NO;
    _internalScrollView.clipsToBounds = YES;
    _internalScrollView.showsHorizontalScrollIndicator = NO;
    _internalScrollView.showsVerticalScrollIndicator = NO;
    _internalScrollView.scrollEnabled = YES;
    _internalScrollView.directionalLockEnabled = YES;
    _internalScrollView.delaysContentTouches = NO;
    _internalScrollView.canCancelContentTouches = YES;
    _internalScrollView.bounces = YES;
    _internalScrollView.alwaysBounceHorizontal = NO;
    _internalScrollView.alwaysBounceVertical = NO;
    _internalScrollView.decelerationRate = 0.996;
    _internalScrollView.scrollsToTop = NO;
    _internalScrollView.panGestureRecognizer.enabled = YES;
    _internalScrollView.panGestureRecognizer.cancelsTouchesInView = YES;
    _internalScrollView.panGestureRecognizer.maximumNumberOfTouches = 1;
    if (@available(iOS 11.0, *)) _internalScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _internalScrollView.delegate = self;
    [self addSubview:_internalScrollView];

    NSMutableArray *cells = [NSMutableArray arrayWithCapacity:kTOWXV11MaxAvatarsFix3];
    for (NSUInteger i = 0; i < kTOWXV11MaxAvatarsFix3; i++) {
        TOWXV11AvatarCellFix3 *cell = [[TOWXV11AvatarCellFix3 alloc] initWithFrame:CGRectZero];
        cell.avatarIndex = i;
        cell.hidden = YES;
        [cell addTarget:self action:@selector(cellTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_internalScrollView addSubview:cell];
        [cells addObject:cell];
    }
    _cells = cells;
    _currentImages = @[];
    TOWXV11DiagLog("AVATAR", "VIEW-CREATE|fix=3|diameter=44|gap=5|edgeShield=7|physics=0.996|cells=%lu",
                   (unsigned long)kTOWXV11MaxAvatarsFix3);
    return self;
}

- (UIScrollView *)scrollView { return self.internalScrollView; }

- (void)setVertical:(BOOL)vertical {
    if (_vertical == vertical) return;
    _vertical = vertical;
    [self.internalScrollView setContentOffset:CGPointZero animated:NO];
    [self refreshLayoutPreservingOffset:NO];
    TOWXV11DiagLog("AVATAR", "AXIS|fix=3|value=%s", vertical ? "vertical" : "horizontal");
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    _selectedIndex = selectedIndex;
    [self updateCellsAnimated:YES];
}

- (void)applyImages:(NSArray *)images count:(NSUInteger)count selectedIndex:(NSInteger)selectedIndex animated:(BOOL)animated {
    self.currentImages = images ?: @[];
    self.avatarCount = MIN(count, kTOWXV11MaxAvatarsFix3);
    _selectedIndex = selectedIndex;
    [self updateCellsAnimated:animated];
    [self refreshLayoutPreservingOffset:YES];
}

- (void)updateCellsAnimated:(BOOL)animated {
    for (NSUInteger i = 0; i < self.cells.count; i++) {
        TOWXV11AvatarCellFix3 *cell = self.cells[i];
        BOOL available = i < self.avatarCount;
        cell.hidden = !available;
        cell.userInteractionEnabled = available;
        if (!available) continue;
        id value = i < self.currentImages.count ? self.currentImages[i] : nil;
        UIImage *image = [value isKindOfClass:[UIImage class]] ? value : nil;
        [cell applyImage:image selected:(_selectedIndex == (NSInteger)i) animated:animated];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.internalScrollView.frame = self.bounds;
    [self refreshLayoutPreservingOffset:YES];
}

- (void)refreshLayoutPreservingOffset:(BOOL)preserveOffset {
    UIScrollView *scroll = self.internalScrollView;
    if (scroll.tracking || scroll.dragging || scroll.decelerating) {
        self.layoutPending = YES;
        return;
    }
    self.layoutPending = NO;

    CGFloat width = CGRectGetWidth(self.bounds), height = CGRectGetHeight(self.bounds);
    if (width < 2.0 || height < 2.0) return;

    CGFloat diameter = kTOWXV11AvatarDiameterFix3;
    CGFloat spacing = kTOWXV11SpacingFix3;
    CGFloat padding = kTOWXV11PaddingFix3;
    CGFloat edgeShield = kTOWXV11EdgeShieldFix3;
    CGFloat visualGap = kTOWXV11VisualGapFix3;
    CGFloat total = self.avatarCount ? diameter * self.avatarCount + spacing * (self.avatarCount - 1) : 0.0;
    CGPoint oldOffset = scroll.contentOffset;

    if (self.vertical) {
        CGFloat contentHeight = MAX(height, total + padding * 2.0);
        CGFloat x = edgeShield + visualGap;
        if (x + diameter > width) x = MAX(0.0, width - diameter - padding);
        scroll.contentSize = CGSizeMake(width, contentHeight);
        scroll.alwaysBounceVertical = contentHeight > height + 0.5;
        scroll.alwaysBounceHorizontal = NO;
        for (NSUInteger i = 0; i < self.avatarCount; i++) {
            self.cells[i].frame = CGRectMake(x, padding + i * (diameter + spacing), diameter, diameter);
        }
    } else {
        CGFloat contentWidth = MAX(width, total + padding * 2.0);
        CGFloat y = edgeShield + visualGap;
        if (y + diameter > height) y = MAX(0.0, height - diameter - padding);
        scroll.contentSize = CGSizeMake(contentWidth, height);
        scroll.alwaysBounceHorizontal = contentWidth > width + 0.5;
        scroll.alwaysBounceVertical = NO;
        for (NSUInteger i = 0; i < self.avatarCount; i++) {
            self.cells[i].frame = CGRectMake(padding + i * (diameter + spacing), y, diameter, diameter);
        }
    }

    if (preserveOffset) {
        CGFloat maxX = MAX(0.0, scroll.contentSize.width - width);
        CGFloat maxY = MAX(0.0, scroll.contentSize.height - height);
        CGPoint clamped = CGPointMake(MIN(MAX(oldOffset.x, 0.0), maxX), MIN(MAX(oldOffset.y, 0.0), maxY));
        [scroll setContentOffset:clamped animated:NO];
    } else {
        [scroll setContentOffset:CGPointZero animated:NO];
    }

    CGFloat range = self.vertical ? MAX(0.0, scroll.contentSize.height - height) : MAX(0.0, scroll.contentSize.width - width);
    if (fabs(range - self.lastLoggedRange) > 0.5 || self.lastLoggedVertical != self.vertical || self.lastLoggedCount != self.avatarCount) {
        self.lastLoggedRange = range;
        self.lastLoggedVertical = self.vertical;
        self.lastLoggedCount = self.avatarCount;
        TOWXV11DiagLog("AVATAR", "LAYOUT|fix=3|axis=%s|count=%lu|viewport=%.1f|content=%.1f|range=%.1f|diameter=44|gap=5|edgeShield=7",
                       self.vertical ? "vertical" : "horizontal",
                       (unsigned long)self.avatarCount,
                       self.vertical ? height : width,
                       self.vertical ? scroll.contentSize.height : scroll.contentSize.width,
                       range);
    }
}

- (void)cellTapped:(TOWXV11AvatarCellFix3 *)cell {
    if (cell.avatarIndex >= self.avatarCount) return;
    TOWXV11DiagLog("AVATAR", "TAP|fix=3|index=%lu|axis=%s", (unsigned long)cell.avatarIndex, self.vertical ? "vertical" : "horizontal");
    if (self.tapHandler) self.tapHandler(cell.avatarIndex);
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    for (TOWXV11AvatarCellFix3 *cell in self.cells) cell.highlighted = NO;
    CGFloat range = self.vertical ? MAX(0.0, scrollView.contentSize.height - scrollView.bounds.size.height) : MAX(0.0, scrollView.contentSize.width - scrollView.bounds.size.width);
    TOWXV11DiagLog("AVATAR", "SCROLL-BEGIN|fix=3|axis=%s|range=%.1f|velocity={%.2f,%.2f}",
                   self.vertical ? "vertical" : "horizontal", range,
                   [scrollView.panGestureRecognizer velocityInView:scrollView].x,
                   [scrollView.panGestureRecognizer velocityInView:scrollView].y);
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    TOWXV11DiagLog("AVATAR", "SCROLL-DRAG-END|fix=3|decelerate=%d|offset={%.1f,%.1f}", decelerate ? 1 : 0, scrollView.contentOffset.x, scrollView.contentOffset.y);
    if (!decelerate && self.layoutPending) [self refreshLayoutPreservingOffset:YES];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    TOWXV11DiagLog("AVATAR", "SCROLL-END|fix=3|offset={%.1f,%.1f}", scrollView.contentOffset.x, scrollView.contentOffset.y);
    if (self.layoutPending) [self refreshLayoutPreservingOffset:YES];
}
@end

__attribute__((constructor)) static void TOWXV11AvatarFix3Marker(void) {
    TOWXV11DiagLog("AVATAR", "LOADED|Smooth1-FIX3|15-cells+44pt+5pt-gap+smooth-scroll");
}
