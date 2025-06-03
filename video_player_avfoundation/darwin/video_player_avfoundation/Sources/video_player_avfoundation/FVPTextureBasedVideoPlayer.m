// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "./include/video_player_avfoundation/FVPTextureBasedVideoPlayer.h"
#import "./include/video_player_avfoundation/FVPTextureBasedVideoPlayer_Test.h"
#import "AVAssetTrackUtils.h"
#import "FVPVideoPlayer.h"

@interface FVPTextureBasedVideoPlayer ()
// The CALayer associated with the Flutter view this plugin is associated with, if any.
@property(nonatomic, readonly) CALayer *flutterViewLayer;
// The updater that drives callbacks to the engine to indicate that a new frame is ready.
@property(nonatomic) FVPFrameUpdater *frameUpdater;
// The display link that drives frameUpdater.
@property(nonatomic) FVPDisplayLink *displayLink;
// The latest buffer obtained from video output. This is stored so that it can be returned from
// copyPixelBuffer again if nothing new is available, since the engine has undefined behavior when
// returning NULL.
@property(nonatomic) CVPixelBufferRef latestPixelBuffer;
// The time that represents when the next frame displays.
@property(nonatomic) CFTimeInterval targetTime;
// Whether to enqueue textureFrameAvailable from copyPixelBuffer.
@property(nonatomic) BOOL selfRefresh;
// The time that represents the start of average frame duration measurement.
@property(nonatomic) CFTimeInterval startTime;
// The number of frames since the start of average frame duration measurement.
@property(nonatomic) int framesCount;
// The latest frame duration since there was significant change.
@property(nonatomic) CFTimeInterval latestDuration;
// Whether a new frame needs to be provided to the engine regardless of the current play/pause state
// (e.g., after a seek while paused). If YES, the display link should continue to run until the next
// frame is successfully provided.
@property(nonatomic, assign) BOOL waitingForFrame;
@property(nonatomic, copy) void (^onDisposed)(int64_t);
@property(nonatomic) CGAffineTransform preferredTransform;
@property(nonatomic) FlutterEventSink eventSink;
@end

static void *timeRangeContext = &timeRangeContext;
static void *statusContext = &statusContext;
static void *presentationSizeContext = &presentationSizeContext;
static void *durationContext = &durationContext;
static void *playbackLikelyToKeepUpContext = &playbackLikelyToKeepUpContext;
static void *rateContext = &rateContext;

@implementation FVPTextureBasedVideoPlayer
- (instancetype)initWithAsset:(NSString *)asset
                 frameUpdater:(FVPFrameUpdater *)frameUpdater
                  displayLink:(FVPDisplayLink *)displayLink
                    avFactory:(id<FVPAVFactory>)avFactory
                    registrar:(NSObject<FlutterPluginRegistrar> *)registrar
                   onDisposed:(void (^)(int64_t))onDisposed {
  return [self initWithURL:[NSURL fileURLWithPath:[FVPVideoPlayer absolutePathForAssetName:asset]]
              frameUpdater:frameUpdater
               displayLink:displayLink
               httpHeaders:@{}
                 avFactory:avFactory
                 registrar:registrar
                onDisposed:onDisposed];
}

- (instancetype)initWithURL:(NSURL *)url
               frameUpdater:(FVPFrameUpdater *)frameUpdater
                displayLink:(FVPDisplayLink *)displayLink
                httpHeaders:(nonnull NSDictionary<NSString *, NSString *> *)headers
                  avFactory:(id<FVPAVFactory>)avFactory
                  registrar:(NSObject<FlutterPluginRegistrar> *)registrar
                 onDisposed:(void (^)(int64_t))onDisposed {
  NSDictionary<NSString *, id> *options = nil;
  if ([headers count] != 0) {
    options = @{@"AVURLAssetHTTPHeaderFieldsKey" : headers};
  }
  AVURLAsset *urlAsset = [AVURLAsset URLAssetWithURL:url options:options];
  AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:urlAsset];
  return [self initWithPlayerItem:item
                     frameUpdater:frameUpdater
                      displayLink:displayLink
                        avFactory:avFactory
                        registrar:registrar
                       onDisposed:onDisposed];
}

- (instancetype)initWithPlayerItem:(AVPlayerItem *)item
                      frameUpdater:(FVPFrameUpdater *)frameUpdater
                       displayLink:(FVPDisplayLink *)displayLink
                         avFactory:(id<FVPAVFactory>)avFactory
                         registrar:(NSObject<FlutterPluginRegistrar> *)registrar
                        onDisposed:(void (^)(int64_t))onDisposed {
  self = [super initWithPlayerItem:item avFactory:avFactory registrar:registrar];

  if (self) {
    _frameUpdater = frameUpdater;
    _displayLink = displayLink;
    _frameUpdater.displayLink = _displayLink;
    _selfRefresh = true;
    _onDisposed = [onDisposed copy];

    // This is to fix 2 bugs: 1. blank video for encrypted video streams on iOS 16
    // (https://github.com/flutter/flutter/issues/111457) and 2. swapped width and height for some
    // video streams (not just iOS 16).  (https://github.com/flutter/flutter/issues/109116). An
    // invisible AVPlayerLayer is used to overwrite the protection of pixel buffers in those streams
    // for issue #1, and restore the correct width and height for issue #2.
    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    [self.flutterViewLayer addSublayer:self.playerLayer];
  }
  return self;
}

NS_INLINE CGFloat radiansToDegrees(CGFloat radians) {
  CGFloat degrees = radians * (180.0 / M_PI);
  return degrees < 0 ? degrees + 360.0 : degrees;
}
const int64_t TIME_UNSET = -9223372036854775807;

NS_INLINE int64_t FVPCMTimeToMillis(CMTime time) {
  // When CMTIME_IS_INDEFINITE return a value that matches TIME_UNSET from ExoPlayer2 on Android.
  // Fixes https://github.com/flutter/flutter/issues/48670
  if (CMTIME_IS_INDEFINITE(time)) return TIME_UNSET;
  if (time.timescale == 0) return 0;
  return time.value * 1000 / time.timescale;
}

- (void)setupEventSinkIfReadyToPlay {
  if (self.eventSink && !self.isInitialized) {
    AVPlayerItem *currentItem = self.player.currentItem;
    CGSize size = currentItem.presentationSize;
    CGFloat width = size.width;
    CGFloat height = size.height;

    // Wait until tracks are loaded to check duration or if there are any videos.
    AVAsset *asset = currentItem.asset;
    if ([asset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded) {
      void (^trackCompletionHandler)(void) = ^{
        if ([asset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded) {
          // Cancelled, or something failed.
          return;
        }
        // This completion block will run on an AVFoundation background queue.
        // Hop back to the main thread to set up event sink.
        [self performSelector:_cmd onThread:NSThread.mainThread withObject:self waitUntilDone:NO];
      };
      [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ]
                           completionHandler:trackCompletionHandler];
      return;
    }

    BOOL hasVideoTracks = [asset tracksWithMediaType:AVMediaTypeVideo].count != 0;
    BOOL hasNoTracks = asset.tracks.count == 0;

    // The player has not yet initialized when it has no size, unless it is an audio-only track.
    // HLS m3u8 video files never load any tracks, and are also not yet initialized until they have
    // a size.
    if ((hasVideoTracks || hasNoTracks) && height == CGSizeZero.height &&
        width == CGSizeZero.width) {
      return;
    }
    // The player may be initialized but still needs to determine the duration.
    int64_t duration = [self duration];
    if (duration == 0) {
      return;
    }

    self.isInitialized = YES;
    self.eventSink(@{
      @"event" : @"initialized",
      @"duration" : @(duration),
      @"width" : @(width),
      @"height" : @(height)
    });
  }
}

- (AVMutableVideoComposition *)getVideoCompositionWithTransform:(CGAffineTransform)transform
                                                      withAsset:(AVAsset *)asset
                                                 withVideoTrack:(AVAssetTrack *)videoTrack {
  AVMutableVideoCompositionInstruction *instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
  instruction.timeRange = CMTimeRangeMake(kCMTimeZero, [asset duration]);
  AVMutableVideoCompositionLayerInstruction *layerInstruction =
      [AVMutableVideoCompositionLayerInstruction
          videoCompositionLayerInstructionWithAssetTrack:videoTrack];
  [layerInstruction setTransform:self.preferredTransform atTime:kCMTimeZero];

  AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
  instruction.layerInstructions = @[ layerInstruction ];
  videoComposition.instructions = @[ instruction ];

  // If in portrait mode, switch the width and height of the video
  CGFloat width = videoTrack.naturalSize.width;
  CGFloat height = videoTrack.naturalSize.height;
  NSInteger rotationDegrees =
      (NSInteger)round(radiansToDegrees(atan2(self.preferredTransform.b, self.preferredTransform.a)));
  if (rotationDegrees == 90 || rotationDegrees == 270) {
    width = videoTrack.naturalSize.height;
    height = videoTrack.naturalSize.width;
  }
  videoComposition.renderSize = CGSizeMake(width, height);

  // TODO(@recastrodiaz): should we use videoTrack.nominalFrameRate ?
  // Currently set at a constant 30 FPS
  videoComposition.frameDuration = CMTimeMake(1, 30);

  return videoComposition;
}
- (void)updateWithPlayerItem:(AVPlayerItem *)item
                frameUpdater:(FVPFrameUpdater *)frameUpdater
                   avFactory:(id<FVPAVFactory>)avFactory
                   registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    
    if (self.disposed) return;

    // Replace the current item with the new one
    [self.player replaceCurrentItemWithPlayerItem:item];
    
    AVAsset *asset = [item asset];

    // Load the video track and preferred transform asynchronously
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
        if ([asset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded) {
            return;
        }

        NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (tracks.count == 0) {
            return;
        }

        AVAssetTrack *videoTrack = tracks.firstObject;

        [videoTrack loadValuesAsynchronouslyForKeys:@[@"preferredTransform"] completionHandler:^{
            if (self.disposed) return;

            if ([videoTrack statusOfValueForKey:@"preferredTransform" error:nil] == AVKeyValueStatusLoaded) {
            self.preferredTransform = FVPGetStandardizedTransformForTrack(videoTrack);
            AVMutableVideoComposition *videoComposition =
                [self getVideoCompositionWithTransform:self.preferredTransform
                                             withAsset:asset
                                        withVideoTrack:videoTrack];
            item.videoComposition = videoComposition;
            }
        }];
    }];

    // Ensure display link continues functioning with the new item
    self.frameUpdater = frameUpdater;
    self.frameUpdater.displayLink = self.displayLink;

    // Recreate and reattach the player layer
    [self.playerLayer removeFromSuperlayer];
    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    [self.flutterViewLayer addSublayer:self.playerLayer];

    // Optional: re-add observers if necessary for KVO updates
    [self addObserversForItem:item player:self.player];
}

- (void )updateWithURL:(NSURL *)url
          frameUpdater:(FVPFrameUpdater *)frameUpdater
           httpHeaders:(nonnull NSDictionary<NSString *, NSString *> *)headers
             avFactory:(id<FVPAVFactory>)avFactory
             registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    NSDictionary<NSString *, id> *options = nil;
    if ([headers count] != 0) {
        options = @{@"AVURLAssetHTTPHeaderFieldsKey" : headers};
    }
    AVURLAsset *urlAsset = [AVURLAsset URLAssetWithURL:url options:options];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:urlAsset];
    [self updateWithPlayerItem:item
                  frameUpdater:frameUpdater
                     avFactory:avFactory
                     registrar:registrar];
}

- (void)updateWithAsset:(NSString *)asset
           frameUpdater:(FVPFrameUpdater *)frameUpdater
              avFactory:(id<FVPAVFactory>)avFactory
              registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    NSString *path = [[NSBundle mainBundle] pathForResource:asset ofType:nil];
#if TARGET_OS_OSX
    // See https://github.com/flutter/flutter/issues/135302
    // TODO(stuartmorgan): Remove this if the asset APIs are adjusted to work better for macOS.
    if (!path) {
        path = [NSURL URLWithString:asset relativeToURL:NSBundle.mainBundle.bundleURL].path;
    }
#endif
    [self updateWithURL:[NSURL fileURLWithPath:path]
           frameUpdater:frameUpdater
            httpHeaders:@{}
              avFactory:avFactory
              registrar:registrar];
}

- (void)addObserversForItem:(AVPlayerItem *)item player:(AVPlayer *)player {
  [item addObserver:self
         forKeyPath:@"loadedTimeRanges"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:timeRangeContext];
  [item addObserver:self
         forKeyPath:@"status"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:statusContext];
  [item addObserver:self
         forKeyPath:@"presentationSize"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:presentationSizeContext];
  [item addObserver:self
         forKeyPath:@"duration"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:durationContext];
  [item addObserver:self
         forKeyPath:@"playbackLikelyToKeepUp"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackLikelyToKeepUpContext];

  // Add observer to AVPlayer instead of AVPlayerItem since the AVPlayerItem does not have a "rate"
  // property
  [player addObserver:self
           forKeyPath:@"rate"
              options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
              context:rateContext];

  // Add an observer that will respond to itemDidPlayToEndTime
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(itemDidPlayToEndTime:)
                                               name:AVPlayerItemDidPlayToEndTimeNotification
                                             object:item];
}

- (void)observeValueForKeyPath:(NSString *)path
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
  if (context == timeRangeContext) {
    if (self.eventSink != nil) {
      NSMutableArray<NSArray<NSNumber *> *> *values = [[NSMutableArray alloc] init];
      for (NSValue *rangeValue in [object loadedTimeRanges]) {
        CMTimeRange range = [rangeValue CMTimeRangeValue];
        int64_t start = FVPCMTimeToMillis(range.start);
        [values addObject:@[ @(start), @(start + FVPCMTimeToMillis(range.duration)) ]];
      }
      self.eventSink(@{@"event" : @"bufferingUpdate", @"values" : values});
    }
  } else if (context == statusContext) {
    AVPlayerItem *item = (AVPlayerItem *)object;
    switch (item.status) {
      case AVPlayerItemStatusFailed:
        if (self.eventSink != nil) {
          self.eventSink([FlutterError
              errorWithCode:@"VideoError"
                    message:[@"Failed to load video: "
                                stringByAppendingString:[item.error localizedDescription]]
                    details:nil]);
        }
        break;
      case AVPlayerItemStatusUnknown:
        break;
      case AVPlayerItemStatusReadyToPlay:
        [item addOutput:self.videoOutput];
        [self setupEventSinkIfReadyToPlay];
        [self updatePlayingState];
        break;
    }
  } else if (context == presentationSizeContext || context == durationContext) {
    AVPlayerItem *item = (AVPlayerItem *)object;
    if (item.status == AVPlayerItemStatusReadyToPlay) {
      // Due to an apparent bug, when the player item is ready, it still may not have determined
      // its presentation size or duration. When these properties are finally set, re-check if
      // all required properties and instantiate the event sink if it is not already set up.
      [self setupEventSinkIfReadyToPlay];
      [self updatePlayingState];
    }
  } else if (context == playbackLikelyToKeepUpContext) {
    [self updatePlayingState];
    if ([[self.player currentItem] isPlaybackLikelyToKeepUp]) {
      if (self.eventSink != nil) {
        self.eventSink(@{@"event" : @"bufferingEnd"});
      }
    } else {
      if (self.eventSink != nil) {
        self.eventSink(@{@"event" : @"bufferingStart"});
      }
    }
  } else if (context == rateContext) {
    // Important: Make sure to cast the object to AVPlayer when observing the rate property,
    // as it is not available in AVPlayerItem.
    AVPlayer *player = (AVPlayer *)object;
    if (self.eventSink != nil) {
      self.eventSink(
          @{@"event" : @"isPlayingStateUpdate", @"isPlaying" : player.rate > 0 ? @YES : @NO});
    }
  }
}

- (void)dealloc {
  CVBufferRelease(_latestPixelBuffer);
}

- (void)setTextureIdentifier:(int64_t)textureIdentifier {
  self.frameUpdater.textureIdentifier = textureIdentifier;
}

- (void)expectFrame {
  self.waitingForFrame = YES;

  _displayLink.running = YES;
}

#pragma mark - Private methods

- (CALayer *)flutterViewLayer {
#if TARGET_OS_OSX
  return self.registrar.view.layer;
#else
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  // TODO(hellohuanlin): Provide a non-deprecated codepath. See
  // https://github.com/flutter/flutter/issues/104117
  UIViewController *root = UIApplication.sharedApplication.keyWindow.rootViewController;
#pragma clang diagnostic pop
  return root.view.layer;
#endif
}

#pragma mark - Overrides

- (void)updatePlayingState {
  [super updatePlayingState];
  // If the texture is still waiting for an expected frame, the display link needs to keep
  // running until it arrives regardless of the play/pause state.
  _displayLink.running = self.isPlaying || self.waitingForFrame;
}

- (void)seekTo:(int64_t)location completionHandler:(void (^)(BOOL))completionHandler {
  CMTime previousCMTime = self.player.currentTime;
  [super seekTo:location
      completionHandler:^(BOOL completed) {
        if (CMTimeCompare(self.player.currentTime, previousCMTime) != 0) {
          // Ensure that a frame is drawn once available, even if currently paused. In theory a
          // race is possible here where the new frame has already drawn by the time this code
          // runs, and the display link stays on indefinitely, but that should be relatively
          // harmless. This must use the display link rather than just informing the engine that a
          // new frame is available because the seek completing doesn't guarantee that the pixel
          // buffer is already available.
          [self expectFrame];
        }

        if (completionHandler) {
          completionHandler(completed);
        }
      }];
}

- (void)disposeSansEventChannel {
  // This check prevents the crash caused by removing the KVO observers twice.
  // When performing a Hot Restart, the leftover players are disposed once directly
  // by [FVPVideoPlayerPlugin initialize:] method and then disposed again by
  // [FVPVideoPlayer onTextureUnregistered:] call leading to possible over-release.
  if (self.disposed) {
    return;
  }

  [super disposeSansEventChannel];

  [self.playerLayer removeFromSuperlayer];

  _displayLink = nil;
}

- (void)dispose {
  [super dispose];

  _onDisposed(self.frameUpdater.textureIdentifier);
}

#pragma mark - FlutterTexture

- (CVPixelBufferRef)copyPixelBuffer {
  // If the difference between target time and current time is longer than this fraction of frame
  // duration then reset target time.
  const float resetThreshold = 0.5;

  // Ensure video sampling at regular intervals. This function is not called at exact time intervals
  // so CACurrentMediaTime returns irregular timestamps which causes missed video frames. The range
  // outside of which targetTime is reset should be narrow enough to make possible lag as small as
  // possible and at the same time wide enough to avoid too frequent resets which would lead to
  // irregular sampling.
  // TODO: Ideally there would be a targetTimestamp of display link used by the flutter engine.
  // https://github.com/flutter/flutter/issues/159087
  CFTimeInterval currentTime = CACurrentMediaTime();
  CFTimeInterval duration = self.frameUpdater.frameDuration;
  if (fabs(self.targetTime - currentTime) > duration * resetThreshold) {
    self.targetTime = currentTime;
  }
  self.targetTime += duration;

  CVPixelBufferRef buffer = NULL;
  CMTime outputItemTime = [self.videoOutput itemTimeForHostTime:self.targetTime];
  if ([self.videoOutput hasNewPixelBufferForItemTime:outputItemTime]) {
    buffer = [self.videoOutput copyPixelBufferForItemTime:outputItemTime itemTimeForDisplay:NULL];
    if (buffer) {
      // Balance the owned reference from copyPixelBufferForItemTime.
      CVBufferRelease(self.latestPixelBuffer);
      self.latestPixelBuffer = buffer;
    }
  }

  if (self.waitingForFrame && buffer) {
    self.waitingForFrame = NO;
    // If the display link was only running temporarily to pick up a new frame while the video was
    // paused, stop it again.
    if (!self.isPlaying) {
      self.displayLink.running = NO;
    }
  }

  // Calling textureFrameAvailable only from within displayLinkFired would require a non-trivial
  // solution to minimize missed video frames due to race between displayLinkFired, copyPixelBuffer
  // and place where is _textureFrameAvailable reset to false in the flutter engine.
  // TODO: Ideally FlutterTexture would support mode of operation where the copyPixelBuffer is
  // called always or some other alternative, instead of on demand by calling textureFrameAvailable.
  // https://github.com/flutter/flutter/issues/159162
  if (self.displayLink.running && self.selfRefresh) {
    // The number of frames over which to measure average frame duration.
    const int windowSize = 10;
    // If measured average frame duration is shorter than this fraction of frame duration obtained
    // from display link then rely solely on refreshes from display link.
    const float durationThreshold = 0.5;
    // If duration changes by this fraction or more then reset average frame duration measurement.
    const float resetFraction = 0.01;

    if (fabs(duration - self.latestDuration) >= self.latestDuration * resetFraction) {
      self.startTime = currentTime;
      self.framesCount = 0;
      self.latestDuration = duration;
    }
    if (self.framesCount == windowSize) {
      CFTimeInterval averageDuration = (currentTime - self.startTime) / windowSize;
      if (averageDuration < duration * durationThreshold) {
        NSLog(@"Warning: measured average duration between frames is unexpectedly short (%f/%f), "
              @"please report this to "
              @"https://github.com/flutter/flutter/issues.",
              averageDuration, duration);
        self.selfRefresh = false;
      }
      self.startTime = currentTime;
      self.framesCount = 0;
    }
    self.framesCount++;

    dispatch_async(dispatch_get_main_queue(), ^{
      [self.frameUpdater.registry textureFrameAvailable:self.frameUpdater.textureIdentifier];
    });
  }

  // Add a retain for the engine, since the copyPixelBufferForItemTime has already been accounted
  // for, and the engine expects an owning reference.
  return CVBufferRetain(self.latestPixelBuffer);
}

- (void)onTextureUnregistered:(NSObject<FlutterTexture> *)texture {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self.disposed) {
      [self dispose];
    }
  });
}

@end
