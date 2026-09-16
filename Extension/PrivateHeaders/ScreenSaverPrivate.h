//
//  ScreenSaverPrivate.h
//  Matrix3DSaverXExtension
//
//  Private API declarations for macOS screensaver extensions.
//

#import <ScreenSaver/ScreenSaver.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - ScreenSaverExtension

@interface ScreenSaverExtension : NSObject
- (instancetype)init;
@end

#pragma mark - ScreenSaverViewController

/// Runtime superclass is NSServiceViewController (ViewBridge).
@interface ScreenSaverViewController : NSViewController

@property (nonatomic, weak, nullable) ScreenSaverView *representedView;
@property (nonatomic, getter=isAnimating) BOOL animating;
@property (nonatomic) BOOL didFirstResize;
@property (nonatomic) BOOL initialAnimationState;
@property (nonatomic) CGSize remoteViewSize;

- (void)startAnimation;
- (void)stopAnimation;
- (void)invalidate;
- (void)loadViewForFrame:(NSRect)frame isPreview:(BOOL)isPreview NS_SWIFT_NAME(loadView(forFrame:isPreview:));

/// ViewBridge size updates — resize in place, do not recreate the Metal view.
- (BOOL)remoteViewSizeChanged:(CGSize)size transaction:(nullable id)transaction;

@end

#pragma mark - ScreenSaverConfigurationViewController

/// Runtime superclass is NSServiceViewController (ViewBridge).
@interface ScreenSaverConfigurationViewController : NSViewController

/// Call when Options should close (OK / Cancel).
- (void)configureSheetDidEnd;

- (void)configureSheetWillPresent;

@end

NS_ASSUME_NONNULL_END
