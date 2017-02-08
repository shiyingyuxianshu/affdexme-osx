//
//  AffdexDemoViewController.m
//
//  Created by Affectiva on 2/22/13.
//  Copyright (c) 2016 Affectiva Inc.
//
//  See the file license.txt for copying permission.

#import "AffdexMeViewController.h"
#import "ClassifierModel.h"
#import "NSImage+Extensions.h"

//#define VIDEO_TEST

static NSString *kSelectedCameraKey = @"selectedCamera";
static NSString *kFacePointsKey = @"drawFacePoints";
static NSString *kFaceBoxKey = @"drawFaceBox";
static NSString *kDrawDominantEmojiKey = @"drawDominantEmoji";
static NSString *kDrawAppearanceIconsKey = @"drawAppearanceIcons";
static NSString *kDrawFrameRateKey = @"drawFrameRate";
static NSString *kDrawFramesToScreenKey = @"drawFramesToScreen";
static NSString *kPointSizeKey = @"pointSize";
static NSString *kProcessRateKey = @"maxProcessRate";
static NSString *kLogoSizeKey = @"logoSize";
static NSString *kLogoOpacityKey = @"logoOpacity";
static NSString *kSmallFaceModeKey = @"smallFaceMode";

@interface AffdexImageView : NSImageView

@end

@implementation AffdexImageView

- (void)keyUp:(NSEvent *)theEvent;
{
    return;
}

@end

@interface AffdexMeViewController ()

@property (assign) NSTimeInterval timestampOfLastUnprocessedFrame;
@property (assign) NSTimeInterval timestampOfLastProcessedFrame;
@property (strong) NSDictionary *entries;
@property (strong) NSEnumerator *entryEnumerator;
@property (strong) NSDictionary *jsonEntry;
@property (strong) NSDictionary *videoEntry;
@property (strong) NSString *jsonFilename;
@property (strong) NSString *mediaFilename;

@property (strong) NSMutableArray *facePointsToDraw;
@property (strong) NSMutableArray *faceRectsToDraw;

@property (strong) NSArray *emotions;   // the array of dictionaries of all emotion classifiers
@property (strong) NSArray *expressions; // the array of dictionaries of all expression classifiers
@property (strong) NSArray *emojis; // the array of dictionaries of all emoji classifiers

@property (strong) NSMutableArray *classifiers;

@property (strong) NSImage *maleImage;
@property (strong) NSImage *femaleImage;
@property (strong) NSImage *unknownImage;
@property (strong) NSImage *maleImageWithGlasses;
@property (strong) NSImage *femaleImageWithGlasses;
@property (strong) NSImage *unknownImageWithGlasses;
@property (assign) CGRect genderRect;
@property (assign) AFDXCameraType cameraToUse;
@property (strong) AVAudioPlayer *audioPlayer;

@property (strong) NSArray *faces;

@property (assign) BOOL multifaceMode;
@property (strong) ExpressionViewController *dominantEmotionOrExpression;


@property (assign) CGFloat fpsUnprocessed;
@property (assign) CGFloat fpsProcessed;

@end

@implementation AffdexMeViewController

#pragma mark -
#pragma mark AFDXDetectorDelegate Methods

#ifdef VIDEO_TEST
- (void)detectorDidFinishProcessing:(AFDXDetector *)detector;
{
    [self stopDetector];
}
#endif

- (void)processedImageReady:(AFDXDetector *)detector
                      image:(NSImage *)image
                      faces:(NSDictionary *)faces
                     atTime:(NSTimeInterval)time;
{
    self.faces = [faces allValues];
    
    
    // compute frames per second and show
    static NSUInteger smoothCount = 0;
    static const NSUInteger smoothInterval = 10;
    static NSTimeInterval interval = 0;
    
    if (smoothCount++ % smoothInterval == 0)
    {
        interval = (time - self.timestampOfLastProcessedFrame);
        smoothCount = 1;
    }
    else
    {
        interval += (time - self.timestampOfLastProcessedFrame);
    }
    
    if (interval > 0 && smoothCount > 0)
    {
        self.fpsProcessed = 1.0 / (interval / smoothCount);
    }
    
    self.timestampOfLastProcessedFrame = time;

    // setup arrays of points and rects
    self.facePointsToDraw = [NSMutableArray new];
    self.faceRectsToDraw = [NSMutableArray new];

    // Handle each metric in the array
    for (AFDXFace *face in [faces allValues])
    {
        NSDictionary *faceData = face.userInfo;
        NSArray *viewControllers = [faceData objectForKey:@"viewControllers"];
        
        [self.facePointsToDraw addObjectsFromArray:face.facePoints];
        [self.faceRectsToDraw addObject:[NSValue valueWithRect:face.faceBounds]];

        // get dominant emoji
        [face.userInfo setObject:[NSNumber numberWithInt:face.emojis.dominantEmoji] forKey:@"dominantEmoji"];
        
        // check if selectedClassifiers is dirty -- if so, update classifier models associated with expression view controllers
        if (self.selectedClassifiersDirty == YES)
        {
            NSArray *selectedClassifiers = [[NSUserDefaults standardUserDefaults] objectForKey:kSelectedClassifiersKey];
            NSUInteger selectedClassifiersCount = [selectedClassifiers count];
            CGFloat maxWidth = 0;
            
            for (int i = 0; i < [viewControllers count]; i++)
            {
                ExpressionViewController *vc = [viewControllers objectAtIndex:i];
                if (i < selectedClassifiersCount)
                {
                    NSString *classifierName = [selectedClassifiers objectAtIndex:i];
                    ClassifierModel *model = [ClassifierModel modelWithName:classifierName];
                    [vc setClassifier:model];
                    
                    // This is here to force the loading of the view's XIB file
                    NSRect f = vc.view.frame;
                    
                    if ([vc.expressionLabel.stringValue length] > 0)
                    {
                        CGSize size = [vc.expressionLabel.stringValue sizeWithAttributes:@{NSFontAttributeName:vc.expressionLabel.font}];
                        maxWidth = fmax(maxWidth, size.width);
                    }
                }
                else
                {
                    [vc setClassifier:nil];
                }
            }
            
            // add padding to maxWidth
            maxWidth += maxWidth * .10;
            
            for (int i = 0; i < [viewControllers count]; i++)
            {
                ExpressionViewController *vc = [viewControllers objectAtIndex:i];
                if (i < selectedClassifiersCount)
                {
                    NSRect frame = vc.view.frame;
                    frame.size.width = maxWidth;
                    vc.view.frame = frame;
                }
            }
        }
        
        // update scores
        for (ExpressionViewController *v in viewControllers)
        {
            NSString *scoreProperty = v.classifier.scoreProperty;
            if (nil != scoreProperty)
            {
                CGFloat score = [[face valueForKeyPath:scoreProperty] floatValue];
                if (!isnan(score))
                {
                    v.metric = score;
                }
            }
        }
    }
    self.selectedClassifiersDirty = NO;
};

- (void)unprocessedImageReady:(AFDXDetector *)detector image:(NSImage *)image atTime:(NSTimeInterval)time;
{
    NSImage *newImage = image;
    self.statsView.hidden = !self.drawFrameRate;
    
    if (self.drawFramesToScreen == NO)
    {
        return;
    }
    
    for (AFDXFace *face in self.faces) {
        NSRect faceBounds = face.faceBounds;
        //faceBounds.origin.y = self.view.bounds.size.height - faceBounds.origin.y;
        
        NSImage *genderImage = nil;
        switch (face.appearance.gender) {
            case AFDX_GENDER_MALE:
                genderImage = self.maleImage;
                if (face.appearance.glasses == AFDX_GLASSES_YES) {
                    genderImage = self.maleImageWithGlasses;
                }
                break;
            case AFDX_GENDER_FEMALE:
                genderImage = self.femaleImage;
                if (face.appearance.glasses == AFDX_GLASSES_YES) {
                    genderImage = self.femaleImageWithGlasses;
                }
                break;
            case AFDX_GENDER_UNKNOWN:
                genderImage = self.unknownImage;
                if (face.appearance.glasses == AFDX_GLASSES_YES) {
                    genderImage = self.unknownImageWithGlasses;
                }
                break;
        }

        // create array of images and rects to do all drawing at once
        NSMutableArray *imagesArray = [NSMutableArray array];
        NSMutableArray *rectsArray = [NSMutableArray array];
        
        // add dominant emoji
        if (self.drawDominantEmoji) {
            Emoji dominantEmoji = [[face.userInfo objectForKey:@"dominantEmoji"] intValue];
            if (dominantEmoji != AFDX_EMOJI_NONE) {
                for (ClassifierModel *model in self.emojis) {
                    NSNumber *code = model.emojiCode;
                    if (dominantEmoji == [code intValue]) {
                        // match!
                        NSImage *emojiImage = model.image;
                        if (nil != emojiImage) {
                            // resize bounds to be relative in size to bounding box
                            CGSize size = emojiImage.size;
                            CGFloat aspectRatio = size.height / size.width;
                            size.width = faceBounds.size.width * .33;
                            size.height = size.width * aspectRatio;
                            
                            CGRect rect = CGRectMake(faceBounds.origin.x + faceBounds.size.width,
                                                     image.size.height - (faceBounds.origin.y) - (size.height),
                                                     size.width,
                                                     size.height);
                            [imagesArray addObject:emojiImage];
                            [rectsArray addObject:[NSValue valueWithRect:rect]];
                            break;
                        }
                    }
                }
            }
        }

        if (self.drawAppearanceIcons) {
            // add gender image
            if (genderImage != nil) {
                // resize bounds to be relative in size to bounding box
                CGSize size = genderImage.size;
                CGFloat aspectRatio = size.height / size.width;
                size.width = faceBounds.size.width * .33;
                size.height = size.width * aspectRatio;
                
                CGRect rect = CGRectMake(faceBounds.origin.x + faceBounds.size.width,
                                         image.size.height - (faceBounds.origin.y) - (faceBounds.size.height),
                                         size.width,
                                         size.height);
                [imagesArray addObject:genderImage];
                [rectsArray addObject:[NSValue valueWithRect:rect]];
            }

            // add dominant emotion/expression
            if (self.multifaceMode == TRUE) {
                CGFloat dominantScore = -9999;
                NSString *dominantName = @"NONAME";
             
                for (NSDictionary *d in self.emotions) {
                    NSString *name = [d objectForKey:@"name"];
                    CGFloat score = [[face valueForKeyPath:[d objectForKey:@"score"]] floatValue];
                    // don't allow valence as per Steve H's suggestion
                    if ([name isEqualToString:@"Valence"]) {
                        continue;
                    }
                    if (score > dominantScore) {
                        dominantScore = score;
                        dominantName = name;
                    }
                }
            }
        }
        
        // do drawing here
        NSColor *faceBoundsColor = nil;
        
        if (face.emotions.valence >= 20)
        {
            faceBoundsColor = [NSColor colorWithRed:0.0 green:0.2 blue:0.0 alpha:1.0];
        }
        else if (face.emotions.valence <= -20)
        {
            faceBoundsColor = [NSColor redColor];
        }
        else
        {
            faceBoundsColor = [NSColor whiteColor];
        }
        
        // Position expression views
        NSMutableArray *viewControllers = [face.userInfo objectForKey:@"viewControllers"];
        NSViewController *vc = [viewControllers objectAtIndex:0];
        CGFloat expressionFrameHeight = vc.view.frame.size.height;
        const CGFloat verticalPadding = 6.0;
        CGFloat expressionFrameIncrement = faceBounds.size.height / ([[[NSUserDefaults standardUserDefaults] objectForKey:kMaxClassifiersShownKey] integerValue]) + verticalPadding;
        CGFloat nextY = image.size.height - faceBounds.origin.y - expressionFrameHeight;

        for (ExpressionViewController *vc in viewControllers)
        {
            NSRect frame = vc.view.frame;
            frame.origin.x = faceBounds.origin.x - frame.size.width;
            frame.origin.y = nextY;
            vc.view.frame = frame;
            NSImage *image = [NSImage imageFromView:vc.view];
            [imagesArray addObject:image];
            [rectsArray addObject:[NSValue valueWithRect:frame]];
            nextY -= expressionFrameIncrement;
        }
        
        newImage = [AFDXDetector imageByDrawingPoints:self.drawFacePoints ? self.facePointsToDraw : nil
                                        andRectangles:self.drawFaceBox ? self.faceRectsToDraw : nil
                                            andImages:imagesArray
                                           withRadius:self.pointSize
                                      usingPointColor:[NSColor whiteColor]
                                  usingRectangleColor:faceBoundsColor
                                      usingImageRects:rectsArray
                                              onImage:newImage];
    }

    [self.imageView setImage:newImage];

    // Update image view size to implement scale to fill, where the minimum axis scales to the window size.
    [self updateImageFrameForSize:[newImage size]];

    // Position the logo view and scale elements accordingly.
    [self positionLogoView];

    // compute frames per second and show
    static NSUInteger smoothCount = 0;
    static const NSUInteger smoothInterval = 60;
    static NSTimeInterval interval = 0;
    
    if (smoothCount++ % smoothInterval == 0)
    {
        interval = (time - self.timestampOfLastUnprocessedFrame);
        smoothCount = 1;
    }
    else
    {
        interval += (time - self.timestampOfLastUnprocessedFrame);
    }
    
    if (interval > 0 && smoothCount > 0)
    {
        self.fpsUnprocessed = 1.0 / (interval / smoothCount);
    }

    self.timestampOfLastUnprocessedFrame = time;
    
#ifdef VIDEO_TEST
    static NSTimeInterval last = 0;
    const CGFloat timeConstant = 0.0000001;
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:(time - last) * timeConstant]];
    last = time;
#endif
}

- (void)detector:(AFDXDetector *)detector hasResults:(NSMutableDictionary *)faces forImage:(NSImage *)image atTime:(NSTimeInterval)time;
{
    
    self.fpsProcessedTextField.stringValue = [NSString stringWithFormat:@"FPS(P): %.1f", self.fpsProcessed];
    self.fpsUnprocessedTextField.stringValue = [NSString stringWithFormat:@"FPS(U): %.1f", self.fpsUnprocessed];
    self.resolution.stringValue = [NSString stringWithFormat:@"%.0f x %.0f", image.size.width, image.size.height];

#if 0
    static BOOL frameCount = 0;
    if (frameCount++ % 1 != 0)
    {
        return;
    }
#endif
    
    if (nil == faces)
    {
        [self unprocessedImageReady:detector image:image atTime:time];
    }
    else
    {
        [self processedImageReady:detector image:image faces:faces atTime:time];
    }
}

- (void)detector:(AFDXDetector *)detector didStartDetectingFace:(AFDXFace *)face;
{
    NSMutableArray *viewControllers = [NSMutableArray array];

    NSUInteger count = [[[NSUserDefaults standardUserDefaults] objectForKey:kMaxClassifiersShownKey] integerValue];
    for (int i = 0; i < count; i++)
    {
        ExpressionViewController *vc = [[ExpressionViewController alloc] initWithClassifier:nil];
        [viewControllers addObject:vc];
    }

    face.userInfo = [NSMutableDictionary dictionaryWithObjectsAndKeys:viewControllers, @"viewControllers",
                            [NSNumber numberWithInt:AFDX_EMOJI_NONE], @"dominantEmoji",
                            nil];
    
    self.selectedClassifiersDirty = YES;
}

- (void)detector:(AFDXDetector *)detector didStopDetectingFace:(AFDXFace *)face;
{
    NSMutableArray *viewControllers = [face.userInfo objectForKey:@"viewControllers"];
    for (ExpressionViewController *vc in viewControllers)
    {
        vc.metric = 0.0;
        [vc.view removeFromSuperview];
    }
    
    face.userInfo = nil;
}


#pragma mark -
#pragma mark ViewController Delegate Methods

+ (void)initialize;
{
    AVCaptureDevice *firstDevice = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
    if (nil != firstDevice)
    {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{kSelectedCameraKey : [firstDevice localizedName]}];
    }
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{kFacePointsKey : [NSNumber numberWithBool:YES]}];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{kFaceBoxKey : [NSNumber numberWithBool:YES]}];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{kPointSizeKey : [NSNumber numberWithFloat:2.0]}];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{kDrawDominantEmojiKey : [NSNumber numberWithBool:YES]}];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{kDrawAppearanceIconsKey : [NSNumber numberWithBool:YES]}];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{kDrawFrameRateKey : [NSNumber numberWithBool:NO]}];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{kDrawFramesToScreenKey : [NSNumber numberWithBool:YES]}];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{kProcessRateKey : [NSNumber numberWithFloat:10.0]}];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{kLogoSizeKey : [NSNumber numberWithFloat:20.0]}];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{kLogoOpacityKey : [NSNumber numberWithFloat:0.0]}];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{kSmallFaceModeKey : [NSNumber numberWithBool:YES]}];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{kSelectedClassifiersKey : [NSMutableArray arrayWithObjects:@"anger", @"joy", @"sadness", @"disgust", @"surprise", @"fear", nil]}];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{kMaxClassifiersShownKey : [NSNumber numberWithInteger:6]}];
}

- (BOOL)canBecomeFirstResponder;
{
    return YES;
}

- (void)dealloc;
{
    self.detector = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Update the image frame to fit the enclosing view bounds using aspect fill, where the entire
// window bounds are filled and the image can overflow in one direction to preserve aspect ratio.
// The image is centered in the main view.
- (void)updateImageFrameForSize:(NSSize)imageSize;
{
    NSRect viewBounds = [self.mainView bounds];
    double windowWidth = viewBounds.size.width;
    double windowHeight = viewBounds.size.height;

    double imageWidth = imageSize.width;
    double imageHeight = imageSize.height;
    if ((imageWidth == 0.0) || (imageHeight == 0.0))
    {
        return;
    }

    NSRect newImageViewFrame;

    double xScale = windowWidth / imageWidth;
    double yScale = windowHeight / imageHeight;

    if (xScale > yScale)
    {
        newImageViewFrame.size.width = imageWidth * xScale;
        newImageViewFrame.size.height = imageHeight * xScale;
    }
    else
    {
        newImageViewFrame.size.width = imageWidth * yScale;
        newImageViewFrame.size.height = imageHeight * yScale;
    }

    // Center the image view in the main window.
    newImageViewFrame.origin.x = (windowWidth - newImageViewFrame.size.width) / 2.0;
    newImageViewFrame.origin.y = (windowHeight - newImageViewFrame.size.height) / 2.0;
    self.imageView.frame = newImageViewFrame;

#if 0
    NSLog(@"Image dimensions: %f x %f\n", imageWidth, imageHeight);
    NSLog(@"xScale, yScale: %f, %f\n", xScale, yScale);
    NSLog(@"Window dimensions: %f x %f\n", windowWidth, windowHeight);
    NSLog(@"Image View origin = %f, %f; dimensions: %f x %f\n", newImageViewFrame.origin.x, newImageViewFrame.origin.y, newImageViewFrame.size.width, newImageViewFrame.size.height);
#endif
}

// Position the logo view and scale it and all of its elements accordingly.
- (void)positionLogoView;
{
    NSRect viewBounds = [self.mainView bounds];
    double windowWidth = viewBounds.size.width;
    double windowHeight = viewBounds.size.height;

    if ((windowWidth == 0.0) || (windowHeight == 0.0))
    {
        return;
    }

    // When set, the partner logo and a divider will be shown above the Affectiva logo.
    // Set to 0 to show only the Affectiva logo in the logo view.
#define SHOW_PARTNER_LOGO 0

    // Position the logo(s) inside the view, while preserving the aspect ratio of each logo.
#define kLogoViewInsetHorizontal 10.0   // View inset from the upper-right corner of the window.
#define kLogoViewInsetVertical   10.0

    // The inset parameters for the view contents are scaled proportionately based
    // on the view size, so the view inset grows proportionately as the view grows.
#define kLogoViewContentInsetHorizontalFactor 0.05   // Range: 0.0 to 0.5
#define kLogoViewContentInsetVerticalFactor   0.05   // Range: 0.0 to 0.5
    CGFloat logoViewScaleFactor = (self.logoSize / 100.0);
    CGFloat logoViewInsetHorizontal = kLogoViewInsetHorizontal;
    CGFloat logoViewInsetVertical = kLogoViewInsetVertical;

    CGFloat newLogoViewWidth = (windowWidth - 2.0 * logoViewInsetHorizontal) * logoViewScaleFactor;
    CGFloat newLogoViewHeight = 0.0;
    CGFloat newLogoViewOriginX = windowWidth - newLogoViewWidth - logoViewInsetHorizontal;

    CGFloat logoViewContentInsetHorizontal = logoViewScaleFactor * windowWidth * kLogoViewContentInsetHorizontalFactor;
    CGFloat logoViewContentInsetVertical = logoViewScaleFactor * windowHeight * kLogoViewContentInsetVerticalFactor;

    CGFloat newLogoViewContentWidthInset = newLogoViewWidth - 2.0 * logoViewContentInsetHorizontal;

    // Position the Affectiva logo.
#if SHOW_PARTNER_LOGO
#define kAffectivaLogoScaleFactor 0.44   // Scale of Affectiva logo relative to the view content size.
    CGFloat newAffectivaLogoWidth = newLogoViewContentWidthInset * kAffectivaLogoScaleFactor;
#else
    CGFloat newAffectivaLogoWidth = newLogoViewContentWidthInset;
#endif
    CGFloat newAffectivaLogoHeight = newAffectivaLogoWidth / self.affectivaLogoAspectRatio;
    CGFloat newAffectivaLogoOriginX = newLogoViewWidth - logoViewContentInsetHorizontal - newAffectivaLogoWidth;
    CGFloat newAffectivaLogoOriginY = logoViewContentInsetVertical;

    NSRect newAffectivaLogoFrame = CGRectMake(newAffectivaLogoOriginX, newAffectivaLogoOriginY, newAffectivaLogoWidth, newAffectivaLogoHeight);
    self.affectivaLogo.imageScaling = NSImageScaleAxesIndependently;
    self.affectivaLogo.frame = newAffectivaLogoFrame;

#if 0
    NSLog(@"Affectiva Logo View origin = %f, %f; dimensions: %f x %f\n", self.affectivaLogo.frame.origin.x, self.affectivaLogo.frame.origin.y, self.affectivaLogo.frame.size.width, self.affectivaLogo.frame.size.height);
#endif

    // Add the lower vertical spacing plus logo height to the view height.
    newLogoViewHeight += logoViewContentInsetVertical + newAffectivaLogoHeight;

#if SHOW_PARTNER_LOGO
    // Position the divider between the logos, centered horizontally.
#define kDividerScaleFactorHorizontal 0.8   // Scale of divider relative to the logo view.
#define kDividerOffsetFactorVertical 0.05    // Top offset factor of divider relative to the logo view.
    CGFloat newDividerVerticalSpacing = newLogoViewWidth * kDividerOffsetFactorVertical;
    CGFloat newDividerWidth = newLogoViewContentWidthInset * kDividerScaleFactorHorizontal;
    CGFloat newDividerHeight = 2.0;

    CGFloat newDividerOriginX = newLogoViewWidth - logoViewContentInsetHorizontal - (newLogoViewContentWidthInset - newDividerWidth) / 2.0 - newDividerWidth;
    CGFloat newDividerOriginY = newLogoViewHeight + newDividerVerticalSpacing;

    NSRect newDividerFrame = CGRectMake(newDividerOriginX, newDividerOriginY, newDividerWidth, newDividerHeight);
    self.logoDivider.frame = newDividerFrame;

    // Add the lower vertical spacing plus divider height to the view height.
    newLogoViewHeight += newDividerVerticalSpacing + newDividerHeight;

    // Update the Affectiva logo frame to center it under the divider.
    newAffectivaLogoOriginX = newLogoViewWidth - logoViewContentInsetHorizontal - (newLogoViewContentWidthInset - newAffectivaLogoWidth) / 2.0 - newAffectivaLogoWidth;
    newAffectivaLogoFrame = CGRectMake(newAffectivaLogoOriginX, newAffectivaLogoOriginY, newAffectivaLogoWidth, newAffectivaLogoHeight);
    self.affectivaLogo.frame = newAffectivaLogoFrame;

    // Position partner logo
    CGFloat newPartnerLogoWidth = newLogoViewContentWidthInset;
    CGFloat newPartnerLogoHeight = newPartnerLogoWidth / self.partnerLogoAspectRatio;
    CGFloat newPartnerLogoOriginX = logoViewContentInsetHorizontal;
    CGFloat newPartnerLogoOriginY = newLogoViewHeight + newDividerVerticalSpacing;

    NSRect newPartnerLogoFrame = CGRectMake(newPartnerLogoOriginX, newPartnerLogoOriginY, newPartnerLogoWidth, newPartnerLogoHeight);
    self.partnerLogo.imageScaling = NSImageScaleAxesIndependently;
    self.partnerLogo.frame = newPartnerLogoFrame;

    // Add the lower vertical spacing plus the partner logo height to the view height.
    newLogoViewHeight += newDividerVerticalSpacing + newPartnerLogoHeight;
#else
    self.logoDivider.hidden = YES;
    self.partnerLogo.hidden = YES;
#endif // SHOW_PARTNER_LOGO

    // Add the top margin onto the logo view height.
    newLogoViewHeight += logoViewContentInsetVertical;

    // Calculate the logo view height last so it encloses all of the internal elements.
    CGFloat newLogoViewOriginY = windowHeight - newLogoViewHeight - logoViewInsetVertical;

    // Finally set the frame for the full view.
    NSRect newLogoViewFrame = CGRectMake(newLogoViewOriginX, newLogoViewOriginY, newLogoViewWidth, newLogoViewHeight);
    self.logoView.frame = newLogoViewFrame;
    self.logoView.layer.backgroundColor = CGColorCreateGenericRGB(1.0, 1.0, 1.0, self.logoOpacity/100.0);
    self.logoView.layer.cornerRadius = 12.0;
    self.logoView.hidden = NO;
}

- (void)viewDidLoad;
{
    [super viewDidLoad];
    
    self.cameraToUse = AFDX_CAMERA_FRONT;
    
    NSString *path = [[NSBundle mainBundle] pathForResource:@"male-noglasses" ofType:@"png" inDirectory:@"media"];
    self.maleImage = [[NSImage alloc] initWithContentsOfFile:path];

    path = [[NSBundle mainBundle] pathForResource:@"female-noglasses" ofType:@"png" inDirectory:@"media"];
    self.femaleImage = [[NSImage alloc] initWithContentsOfFile:path];

    path = [[NSBundle mainBundle] pathForResource:@"male-glasses" ofType:@"png" inDirectory:@"media"];
    self.maleImageWithGlasses = [[NSImage alloc] initWithContentsOfFile:path];

    path = [[NSBundle mainBundle] pathForResource:@"female-glasses" ofType:@"png" inDirectory:@"media"];
    self.femaleImageWithGlasses = [[NSImage alloc] initWithContentsOfFile:path];

    path = [[NSBundle mainBundle] pathForResource:@"unknown-noglasses" ofType:@"png" inDirectory:@"media"];
    self.unknownImage = [[NSImage alloc] initWithContentsOfFile:path];

    path = [[NSBundle mainBundle] pathForResource:@"unknown-glasses" ofType:@"png" inDirectory:@"media"];
    self.unknownImageWithGlasses = [[NSImage alloc] initWithContentsOfFile:path];

#if SHOW_PARTNER_LOGO
    path = [[NSBundle mainBundle] pathForResource:@"Partner_Logo" ofType:@"png" inDirectory:@"."];
    NSSize partnerLogoSize = [[[NSImage alloc] initWithContentsOfFile:path] size];
    self.partnerLogoAspectRatio = (partnerLogoSize.height == 0) ? 1.0 : (partnerLogoSize.width / partnerLogoSize.height);
#endif

    path = [[NSBundle mainBundle] pathForResource:@"Affectiva_Logo_Clear_Background" ofType:@"png" inDirectory:@"."];
    NSSize affectivaLogoSize = [[[NSImage alloc] initWithContentsOfFile:path] size];
    self.affectivaLogoAspectRatio = (affectivaLogoSize.height == 0) ? 1.0 : (affectivaLogoSize.width / affectivaLogoSize.height);

    self.emotions = [ClassifierModel emotions];
    self.expressions = [ClassifierModel expressions];
    self.emojis = [ClassifierModel emojis];
    
    self.logoView.hidden = YES;

    [self.shareButton sendActionOn:NSLeftMouseDownMask];
    [self.shareButton.cell setHighlightsBy:NSContentsCellMask];
}

- (void)viewWillDisappear;
{
    // remove ourself as an observer
    [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:kSelectedCameraKey];
    [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:kSmallFaceModeKey];

    [self stopDetector];
    
    [self resignFirstResponder];
    
    [super viewWillDisappear];
}

- (void)viewWillAppear;
{
    [super viewWillAppear];
    
    self.fpsProcessedTextField.stringValue = @"";
    self.fpsUnprocessedTextField.stringValue = @"";
    self.resolution.stringValue = @"";

    [self.imageView setImage:nil];
    
    NSMutableArray *selectedClassifers = [[NSUserDefaults standardUserDefaults] objectForKey:kSelectedClassifiersKey];
    NSUInteger count = [selectedClassifers count];
    
    for (NSUInteger i = 0; i < count; i++)
    {
        ClassifierModel *m = [ClassifierModel modelWithName:[selectedClassifers objectAtIndex:0]];
        
        [self.classifiers addObject:m];
    }
    
    for (ClassifierModel *m in self.emotions)
    {
        [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithBool:m.enabled] forKey:m.name];
    }

    // add ourself as an observer of various settings
    [[NSUserDefaults standardUserDefaults] addObserver:self
                                            forKeyPath:kSelectedCameraKey
                                               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                               context:(__bridge void *)kSelectedCameraKey];

    [[NSUserDefaults standardUserDefaults] addObserver:self
                                            forKeyPath:kSmallFaceModeKey
                                               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                               context:(__bridge void *)kSmallFaceModeKey];
}

- (void)viewDidAppear;
{
    [super viewDidAppear];
    [self becomeFirstResponder];

#ifdef VIDEO_TEST
    self.mediaFilename = [[NSBundle mainBundle] pathForResource:@"face1" ofType:@"mov"];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.mediaFilename] == YES)
    {
        [self startDetector];
    }
#endif
}

-(void)updateDetectorOnKeyPathChange;
{
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self stopDetector];
    NSError *error = [self startDetector];
    if (nil != error)
    {
        NSAlert *alert = [NSAlert alertWithError:error];
        [alert runModal];

        [NSApp terminate:self];
    }
}

-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *,id> *)change context:(void *)context
{
    if (context == (__bridge void *)kSelectedCameraKey)
    {
        [self updateDetectorOnKeyPathChange];
        return;
    }

    id v = [change objectForKey:NSKeyValueChangeNewKey];
    
    if ([v isKindOfClass:[NSNull class]])
    {
        return;
    }
    
    if (context == (__bridge void *)kFacePointsKey)
    {
        BOOL value = [v boolValue];
        
        self.drawFacePoints = value;
    }
    else
    if (context == (__bridge void *)kFaceBoxKey)
    {
        BOOL value = [v boolValue];
        
        self.drawFaceBox = value;
    }
    else
    if (context == (__bridge void *)kDrawDominantEmojiKey)
    {
        BOOL value = [v boolValue];
            
        self.drawDominantEmoji = value;
    }
    else
    if (context == (__bridge void *)kDrawAppearanceIconsKey)
    {
        BOOL value = [v boolValue];
        
        self.drawAppearanceIcons = value;
    }
    else
    if (context == (__bridge void *)kSmallFaceModeKey)
    {
        BOOL value = [v boolValue];

        if (self.smallFaceMode != value) {
            self.smallFaceMode = value;

            // Restart the detector, after delaying long enough to allow the UI to update the checkbox state.
#define kDetectorRestartDelaySec 0.1
            [(NSObject *)self performSelector:@selector(updateDetectorOnKeyPathChange)
                                   withObject:self
                                   afterDelay:kDetectorRestartDelaySec];
        }
    }
    else
    if (context == (__bridge void *)kDrawFrameRateKey)
    {
        BOOL value = [v boolValue];
        
        self.drawFrameRate = value;
    }
    else
    if (context == (__bridge void *)kDrawFramesToScreenKey)
    {
        BOOL value = [v boolValue];
        
        self.drawFramesToScreen = value;
    }
    else
    if (context == (__bridge void *)kPointSizeKey)
    {
        CGFloat value = [v floatValue];
        
        self.pointSize = value;
    }
    else
    if (context == (__bridge void *)kProcessRateKey)
    {
        CGFloat value = [v floatValue];
        
        self.detector.maxProcessRate = value;
        if (value == 0.0)
        {
            self.fpsProcessed = 0.0;
        }
    }
    else
    if (context == (__bridge void *)kLogoSizeKey)
    {
        CGFloat value = [v floatValue];

        self.logoSize = value;
    }
    else
    if (context == (__bridge void *)kLogoOpacityKey)
    {
        CGFloat value = [v floatValue];

        self.logoOpacity = value;
    }
    else
    {
        self.selectedClassifiersDirty = TRUE;
    }
}

- (NSError *)startDetector;
{
    NSError *result = nil;
    
    [self.detector stop];
    
    NSUInteger maximumFaces = 10;

    // create our detector with our desired facial expresions, using the front facing camera
    
    NSString *localizedName = [[NSUserDefaults standardUserDefaults] objectForKey:kSelectedCameraKey];
    
    AVCaptureDevice *device = nil;
    
    for (device in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo])
    {
        if ([[device localizedName] isEqualToString:localizedName])
        {
            break;
        }
    }
    
    if (nil == device)
    {
        device = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
        [[NSUserDefaults standardUserDefaults] setObject:device.localizedName forKey:kSelectedCameraKey];
    }
    
#ifdef VIDEO_TEST
    // Create the detector with our desired facial expresions using a file as input.
    self.detector = [[AFDXDetector alloc] initWithDelegate:self usingFile:self.mediaFilename maximumFaces:maximumFaces];
#else
    // Create the detector with our desired facial expresions using the currently selected camera.
    self.detector = [[AFDXDetector alloc] initWithDelegate:self
                                        usingCaptureDevice:device
                                              maximumFaces:maximumFaces
                                                  faceMode:self.smallFaceMode ? SMALL_FACES : LARGE_FACES];
#endif
    
    // add ourself as an observer of various settings
    [[NSUserDefaults standardUserDefaults] addObserver:self
                                            forKeyPath:kFacePointsKey
                                               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                               context:(__bridge void *)kFacePointsKey];
    
    [[NSUserDefaults standardUserDefaults] addObserver:self
                                            forKeyPath:kFaceBoxKey
                                               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                               context:(__bridge void *)kFaceBoxKey];
    
    [[NSUserDefaults standardUserDefaults] addObserver:self
                                            forKeyPath:kPointSizeKey
                                               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                               context:(__bridge void *)kPointSizeKey];
    
    [[NSUserDefaults standardUserDefaults] addObserver:self
                                            forKeyPath:kProcessRateKey
                                               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                               context:(__bridge void *)kProcessRateKey];
    
    [[NSUserDefaults standardUserDefaults] addObserver:self
                                            forKeyPath:kLogoSizeKey
                                               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                               context:(__bridge void *)kLogoSizeKey];

    [[NSUserDefaults standardUserDefaults] addObserver:self
                                            forKeyPath:kLogoOpacityKey
                                               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                               context:(__bridge void *)kLogoOpacityKey];

    [[NSUserDefaults standardUserDefaults] addObserver:self
                                            forKeyPath:kDrawDominantEmojiKey
                                               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                               context:(__bridge void *)kDrawDominantEmojiKey];
    
    [[NSUserDefaults standardUserDefaults] addObserver:self
                                            forKeyPath:kDrawAppearanceIconsKey
                                               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                               context:(__bridge void *)kDrawAppearanceIconsKey];
    
    [[NSUserDefaults standardUserDefaults] addObserver:self
                                            forKeyPath:kDrawFrameRateKey
                                               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                               context:(__bridge void *)kDrawFrameRateKey];
    
    [[NSUserDefaults standardUserDefaults] addObserver:self
                                            forKeyPath:kDrawFramesToScreenKey
                                               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                               context:(__bridge void *)kDrawFramesToScreenKey];
    
    [[NSUserDefaults standardUserDefaults] addObserver:self
                                            forKeyPath:kSelectedClassifiersKey
                                               options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                               context:(void *)kSelectedClassifiersKey];
    
    for (NSString *name in [[NSUserDefaults standardUserDefaults] objectForKey:kSelectedClassifiersKey])
    {
        ClassifierModel *m = [ClassifierModel modelWithName:name];
        
        if (m.enabled == TRUE)
        {
            [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithBool:YES] forKey:m.name];
        }
    }
    
    NSInteger maxProcessRate = [[[NSUserDefaults standardUserDefaults] objectForKey:@"maxProcessRate"] integerValue];
    
    self.detector.maxProcessRate = maxProcessRate;
    self.timestampOfLastUnprocessedFrame = 0;
    self.timestampOfLastProcessedFrame = 0;
    
    // tell the detector which facial expressions we want to measure
    [self.detector setDetectAllEmotions:YES];
    [self.detector setDetectAllExpressions:YES];
    [self.detector setDetectEmojis:YES];
    [self.detector enableAnalytics];
    self.detector.gender = TRUE;
    self.detector.glasses = TRUE;
    
    // let's start it up!
    result = [self.detector start];
    if (nil == result)
    {
    }
    
    return result;
}

- (NSError *)stopDetector;
{
    NSError *result = nil;
    
    if (self.detector != nil)
    {
        [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:kDrawFramesToScreenKey];
        [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:kDrawFrameRateKey];
        [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:kDrawAppearanceIconsKey];
        [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:kDrawDominantEmojiKey];
        [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:kSelectedClassifiersKey];
        [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:kFacePointsKey];
        [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:kFaceBoxKey];
        [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:kPointSizeKey];
        [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:kProcessRateKey];
        [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:kLogoSizeKey];
        [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:kLogoOpacityKey];

        result = [self.detector stop];
    }
    self.detector = nil;
    
    return result;
}

// Closing the main window will terminate the app
- (void)windowWillClose:(NSNotification *)notification;
{
    [NSApp terminate:self];
}

// This method activates the Preferences window
- (IBAction)showPreferencesWindow:(id)sender
{
    if (nil == self.preferencesWindowController)
    {
        self.preferencesWindowController = [[PreferencesWindowController alloc] init];
    }
    
    [self.preferencesWindowController showWindow:self];
}

- (IBAction)shareButtonAction:(id)sender;
{
    // hide share button
    [self.shareButton setHidden:TRUE];

    // capture image
    NSImage *image = [NSImage imageFromView:self.view];

    // play sound
    if (self.audioPlayer == nil)
    {
        NSString *path = [[NSBundle mainBundle] pathForResource:@"camera-shutter" ofType:@"mp3" inDirectory:@"media"];
        NSURL *url = [NSURL fileURLWithPath:path];
        
        self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:nil];
        [self.audioPlayer prepareToPlay];
    }
    [self.audioPlayer play];

    // lazily initialize the view's layer
    if (self.view.layer == nil)
    {
        self.view.layer = [CALayer layer];
        self.view.wantsLayer = YES;
    }

    // Flash ON
    CABasicAnimation *theAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    theAnimation.duration = 0.1;
    theAnimation.repeatCount = 1;
    theAnimation.autoreverses = YES;
    theAnimation.fromValue = [NSNumber numberWithFloat:1.0];
    theAnimation.toValue = [NSNumber numberWithFloat:0.0];
    [self.view.layer addAnimation:theAnimation forKey:@"animateOpacity"];
    
    // restore share button and show share service picker
    [self.shareButton setHidden:FALSE];
    NSSharingServicePicker *sharingServicePicker = [[NSSharingServicePicker alloc] initWithItems:@[image]];
    sharingServicePicker.delegate = self;
    
    [sharingServicePicker showRelativeToRect:[sender bounds]
                                      ofView:sender
                               preferredEdge:NSMinYEdge];
}

- (IBAction)showHelp:(id)sender;
{
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://github.com/Affectiva/affdexme-osx"]];
}

@end
