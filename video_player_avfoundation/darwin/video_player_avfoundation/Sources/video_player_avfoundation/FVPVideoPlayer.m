// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "./include/video_player_avfoundation/FVPVideoPlayer.h"
#import "./include/video_player_avfoundation/FVPVideoPlayer_Internal.h"
#import "./include/video_player_avfoundation/FVPVideoPlayer_Test.h"

#import <GLKit/GLKit.h>

#import "./include/video_player_avfoundation/AVAssetTrackUtils.h"

static void *timeRangeContext = &timeRangeContext;
static void *statusContext = &statusContext;
static void *presentationSizeContext = &presentationSizeContext;
static void *durationContext = &durationContext;
static void *playbackLikelyToKeepUpContext = &playbackLikelyToKeepUpContext;
static void *rateContext = &rateContext;

@implementation FVPVideoPlayer
- (instancetype)initWithAsset:(NSString *)asset
                    avFactory:(id<FVPAVFactory>)avFactory
                    registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  return [self initWithURL:[NSURL fileURLWithPath:[FVPVideoPlayer absolutePathForAssetName:asset]]
               httpHeaders:@{}
                 avFactory:avFactory
                 registrar:registrar];
}

- (instancetype)initWithURL:(NSURL *)url
                httpHeaders:(nonnull NSDictionary<NSString *, NSString *> *)headers
                  avFactory:(id<FVPAVFactory>)avFactory
                  registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  NSDictionary<NSString *, id> *options = nil;
  if ([headers count] != 0) {
    options = @{@"AVURLAssetHTTPHeaderFieldsKey" : headers};
  }
  AVURLAsset *urlAsset = [AVURLAsset URLAssetWithURL:url options:options];
  AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:urlAsset];
  return [self initWithPlayerItem:item avFactory:avFactory registrar:registrar];
}

- (instancetype)initWithPlayerItem:(AVPlayerItem *)item
                         avFactory:(id<FVPAVFactory>)avFactory
                         registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");

  _registrar = registrar;
  _avFactory = avFactory; // Store avFactory for later use in update methods.
                         // It was not stored in the original init.

  // Initial setup for the player item and observers
  [self setupPlayerWithItem:item];

  return self;
}

- (void)dealloc {
  if (!_disposed) {
    [self removeKeyValueObservers];
  }
}

+ (NSString *)absolutePathForAssetName:(NSString *)assetName {
  NSString *path = [[NSBundle mainBundle] pathForResource:assetName ofType:nil];
#if TARGET_OS_OSX
  // See https://github.com/flutter/flutter/issues/135302
  // TODO(stuartmorgan): Remove this if the asset APIs are adjusted to work better for macOS.
  if (!path) {
    path = [NSURL URLWithString:assetName relativeToURL:NSBundle.mainBundle.bundleURL].path;
  }
#endif

  return path;
}

// --- New Helper Method ---
- (void)setupPlayerWithItem:(AVPlayerItem *)item {
    // Clean up existing observers and notifications if this is an update
    if (_player && _player.currentItem) {
        [self removeKeyValueObservers];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:AVPlayerItemDidPlayToEndTimeNotification
                                                      object:_player.currentItem];
    }

    AVAsset *asset = [item asset];
    void (^assetCompletionHandler)(void) = ^{
        if ([asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) {
            NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
            if ([tracks count] > 0) {
                AVAssetTrack *videoTrack = tracks[0];
                void (^trackCompletionHandler)(void) = ^{
                    if (self->_disposed) return;
                    if ([videoTrack statusOfValueForKey:@"preferredTransform"
                                                  error:nil] == AVKeyValueStatusLoaded) {
                        self->_preferredTransform = FVPGetStandardizedTransformForTrack(videoTrack);
                        if (CGAffineTransformIsIdentity(self->_preferredTransform)) {
                            return; // No need for video composition if transform is identity
                        }
                        AVMutableVideoComposition *videoComposition =
                        [self getVideoCompositionWithTransform:self->_preferredTransform
                                                     withAsset:asset
                                                withVideoTrack:videoTrack];
                        item.videoComposition = videoComposition;
                    }
                };
                [videoTrack loadValuesAsynchronouslyForKeys:@[ @"preferredTransform" ]
                                          completionHandler:trackCompletionHandler];
            }
        }
    };

    if (!_player) { // Create player only if it doesn't exist (for initial setup)
        _player = [_avFactory playerWithPlayerItem:item];
        _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    } else { // Replace current item if player already exists (for updates)
        [_player replaceCurrentItemWithPlayerItem:item];
    }

    // Configure video output (can be reused if attributes are the same, or recreated if needed)
    if (!_videoOutput) { // Create output only if it doesn't exist
        NSDictionary *pixBuffAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
        };
        _videoOutput = [_avFactory videoOutputWithPixelBufferAttributes:pixBuffAttributes];
    }
    // Note: The output will be added to the new item in observeValueForKeyPath when item.status is AVPlayerItemStatusReadyToPlay

    [self addObserversForItem:item player:_player]; // Add observers to the new item

    [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:assetCompletionHandler];

    // Reset initialization state for a new source
    _isInitialized = NO;
}

// --- New Update Methods ---
- (void)updateWithAsset:(NSString *)asset
              avFactory:(id<FVPAVFactory>)avFactory
              registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    NSString *path = [[NSBundle mainBundle] pathForResource:asset ofType:nil];
#if TARGET_OS_OSX
    if (!path) {
        path = [NSURL URLWithString:asset relativeToURL:NSBundle.mainBundle.bundleURL].path;
    }
#endif
    [self updateWithURL:[NSURL fileURLWithPath:path]
            httpHeaders:@{}
              avFactory:avFactory
              registrar:registrar];
}

- (void)updateWithURL:(NSURL *)url
          httpHeaders:(nonnull NSDictionary<NSString *, NSString *> *)headers
            avFactory:(id<FVPAVFactory>)avFactory
            registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    NSDictionary<NSString *, id> *options = nil;
    if ([headers count] != 0) {
        options = @{@"AVURLAssetHTTPHeaderFieldsKey" : headers};
    }
    AVURLAsset *urlAsset = [AVURLAsset URLAssetWithURL:url options:options];
    AVPlayerItem *newItem = [AVPlayerItem playerItemWithAsset:urlAsset];

    // Assuming _avFactory and _registrar are already set from init or can be updated here
    // For consistency with original init, ensure _avFactory is set.
    _avFactory = avFactory; // Make sure avFactory is updated/set if it's different
    _registrar = registrar; // Make sure registrar is updated/set if it's different

    [self setupPlayerWithItem:newItem];

    // After updating the source, ensure the player state is consistent
    // For example, if it was playing before, it should resume playing.
    [self updatePlayingState]; // This will handle playing/pausing based on _isPlaying
}
// --- End New Update Methods ---


- (void)addObserversForItem:(AVPlayerItem *)item player:(AVPlayer *)player {
  // It's crucial to ensure that previous observers are removed before adding new ones,
  // especially if this method is called during an update.
  // The setupPlayerWithItem now handles removing previous observers.
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

- (void)itemDidPlayToEndTime:(NSNotification *)notification {
  if (_isLooping) {
    AVPlayerItem *p = [notification object];
    [p seekToTime:kCMTimeZero completionHandler:nil];
  } else {
    if (_eventSink) {
      _eventSink(@{@"event" : @"completed"});
    }
  }
}

const int64_t TIME_UNSET = -9223372036854775807;

NS_INLINE int64_t FVPCMTimeToMillis(CMTime time) {
  // When CMTIME_IS_INDEFINITE return a value that matches TIME_UNSET from ExoPlayer2 on Android.
  // Fixes https://github.com/flutter/flutter/issues/48670
  if (CMTIME_IS_INDEFINITE(time)) return TIME_UNSET;
  if (time.timescale == 0) return 0;
  return time.value * 1000 / time.timescale;
}

NS_INLINE CGFloat radiansToDegrees(CGFloat radians) {
  // Input range [-pi, pi] or [-180, 180]
  CGFloat degrees = GLKMathRadiansToDegrees((float)radians);
  if (degrees < 0) {
    // Convert -90 to 270 and -180 to 180
    return degrees + 360;
  }
  // Output degrees in between [0, 360]
  return degrees;
};

- (AVMutableVideoComposition *)getVideoCompositionWithTransform:(CGAffineTransform)transform
                                                      withAsset:(AVAsset *)asset
                                                 withVideoTrack:(AVAssetTrack *)videoTrack {
  AVMutableVideoCompositionInstruction *instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
  instruction.timeRange = CMTimeRangeMake(kCMTimeZero, [asset duration]);
  AVMutableVideoCompositionLayerInstruction *layerInstruction =
      [AVMutableVideoCompositionLayerInstruction
          videoCompositionLayerInstructionWithAssetTrack:videoTrack];
  [layerInstruction setTransform:_preferredTransform atTime:kCMTimeZero];

  AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
  instruction.layerInstructions = @[ layerInstruction ];
  videoComposition.instructions = @[ instruction ];

  // If in portrait mode, switch the width and height of the video
  CGFloat width = videoTrack.naturalSize.width;
  CGFloat height = videoTrack.naturalSize.height;
  NSInteger rotationDegrees =
      (NSInteger)round(radiansToDegrees(atan2(_preferredTransform.b, _preferredTransform.a)));
  if (rotationDegrees == 90 || rotationDegrees == 270) {
    width = videoTrack.naturalSize.height;
    height = videoTrack.naturalSize.width;
  }
  videoComposition.renderSize = CGSizeMake(width, height);

  videoComposition.sourceTrackIDForFrameTiming = videoTrack.trackID;
  if (CMTIME_IS_VALID(videoTrack.minFrameDuration)) {
    videoComposition.frameDuration = videoTrack.minFrameDuration;
  } else {
    NSLog(@"Warning: videoTrack.minFrameDuration for input video is invalid, please report this to "
          @"https://github.com/flutter/flutter/issues with input video attached.");
    videoComposition.frameDuration = CMTimeMake(1, 30);
  }

  return videoComposition;
}

- (void)observeValueForKeyPath:(NSString *)path
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
  if (context == timeRangeContext) {
    if (_eventSink != nil) {
      NSMutableArray<NSArray<NSNumber *> *> *values = [[NSMutableArray alloc] init];
      for (NSValue *rangeValue in [object loadedTimeRanges]) {
        CMTimeRange range = [rangeValue CMTimeRangeValue];
        int64_t start = FVPCMTimeToMillis(range.start);
        [values addObject:@[ @(start), @(start + FVPCMTimeToMillis(range.duration)) ]];
      }
      _eventSink(@{@"event" : @"bufferingUpdate", @"values" : values});
    }
  } else if (context == statusContext) {
    AVPlayerItem *item = (AVPlayerItem *)object;
    switch (item.status) {
      case AVPlayerItemStatusFailed:
        [self sendFailedToLoadVideoEvent];
        break;
      case AVPlayerItemStatusUnknown:
        break;
      case AVPlayerItemStatusReadyToPlay:
        // Ensure _videoOutput is only added once and for the correct item.
        // If _videoOutput is already an output for this item, this call is a no-op.
        // This is safe even if a new item is set.
        if (![item.outputs containsObject:_videoOutput]) {
          [item addOutput:_videoOutput];
        }
        [self setupEventSinkIfReadyToPlay];
        break;
    }
  } else if (context == presentationSizeContext || context == durationContext) {
    AVPlayerItem *item = (AVPlayerItem *)object;
    if (item.status == AVPlayerItemStatusReadyToPlay) {
      [self setupEventSinkIfReadyToPlay];
    }
  } else if (context == playbackLikelyToKeepUpContext) {
    [self updatePlayingState];
    if ([[_player currentItem] isPlaybackLikelyToKeepUp]) {
      if (_eventSink != nil) {
        _eventSink(@{@"event" : @"bufferingEnd"});
      }
    } else {
      if (_eventSink != nil) {
        _eventSink(@{@"event" : @"bufferingStart"});
      }
    }
  } else if (context == rateContext) {
    AVPlayer *player = (AVPlayer *)object;
    if (_eventSink != nil) {
      _eventSink(
          @{@"event" : @"isPlayingStateUpdate", @"isPlaying" : player.rate > 0 ? @YES : @NO});
    }
  }
}

- (void)updatePlayingState {
  if (!_isInitialized) {
    return;
  }
  if (_isPlaying) {
    if (_targetPlaybackSpeed) {
      [self updateRate];
    } else {
      [_player play];
    }
  } else {
    [_player pause];
  }
}

/// Synchronizes the player's playback rate with targetPlaybackSpeed, constrained by the playback
/// rate capabilities of the player's current item.
- (void)updateRate {
  float speed = _targetPlaybackSpeed.floatValue;
  BOOL readyToPlay = _player.currentItem.status == AVPlayerItemStatusReadyToPlay;
  if (speed > 2.0 && !_player.currentItem.canPlayFastForward) {
    if (!readyToPlay) {
      return;
    }
    speed = 2.0;
  }
  if (speed < 1.0 && !_player.currentItem.canPlaySlowForward) {
    if (!readyToPlay) {
      return;
    }
    speed = 1.0;
  }
  _player.rate = speed;
}

- (void)sendFailedToLoadVideoEvent {
  if (_eventSink == nil) {
    return;
  }
  NSError *error;
  if ([self.player.currentItem.asset statusOfValueForKey:@"tracks"
                                                   error:&error] != AVKeyValueStatusFailed) {
    error = self.player.currentItem.error;
  }
  __block NSMutableOrderedSet<NSString *> *details =
      [NSMutableOrderedSet orderedSetWithObject:@"Failed to load video"];
  void (^add)(NSString *) = ^(NSString *detail) {
    if (detail != nil) {
      [details addObject:detail];
    }
  };
  NSError *underlyingError = error.userInfo[NSUnderlyingErrorKey];
  add(error.localizedDescription);
  add(error.localizedFailureReason);
  add(underlyingError.localizedDescription);
  add(underlyingError.localizedFailureReason);
  NSString *message = [details.array componentsJoinedByString:@": "];
  _eventSink([FlutterError errorWithCode:@"VideoError" message:message details:nil]);
}

- (void)setupEventSinkIfReadyToPlay {
  if (_eventSink && !_isInitialized) {
    AVPlayerItem *currentItem = self.player.currentItem;
    CGSize size = currentItem.presentationSize;
    CGFloat width = size.width;
    CGFloat height = size.height;

    AVAsset *asset = currentItem.asset;
    if ([asset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded) {
      void (^trackCompletionHandler)(void) = ^{
        if ([asset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded) {
          return;
        }
        [self performSelector:_cmd onThread:NSThread.mainThread withObject:self waitUntilDone:NO];
      };
      [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ]
                           completionHandler:trackCompletionHandler];
      return;
    }

    BOOL hasVideoTracks = [asset tracksWithMediaType:AVMediaTypeVideo].count != 0;
    BOOL hasNoTracks = currentItem.tracks.count == 0 && asset.tracks.count == 0;

    if ((hasVideoTracks || hasNoTracks) && height == CGSizeZero.height &&
        width == CGSizeZero.width) {
      return;
    }
    int64_t duration = [self duration];
    if (duration == 0) {
      return;
    }

    _isInitialized = YES;
    [self updatePlayingState];

    _eventSink(@{
      @"event" : @"initialized",
      @"duration" : @(duration),
      @"width" : @(width),
      @"height" : @(height)
    });
  }
}

- (void)play {
  _isPlaying = YES;
  [self updatePlayingState];
}

- (void)pause {
  _isPlaying = NO;
  [self updatePlayingState];
}

- (int64_t)position {
  return FVPCMTimeToMillis([_player currentTime]);
}

- (int64_t)duration {
  return FVPCMTimeToMillis([[[_player currentItem] asset] duration]);
}

- (void)seekTo:(int64_t)location completionHandler:(void (^)(BOOL))completionHandler {
  CMTime targetCMTime = CMTimeMake(location, 1000);
  CMTimeValue duration = _player.currentItem.asset.duration.value;
  CMTime tolerance = location == duration ? CMTimeMake(1, 1000) : kCMTimeZero;
  [_player seekToTime:targetCMTime
        toleranceBefore:tolerance
         toleranceAfter:tolerance
      completionHandler:^(BOOL completed) {
        if (completionHandler) {
          completionHandler(completed);
        }
      }];
}

- (void)setIsLooping:(BOOL)isLooping {
  _isLooping = isLooping;
}

- (void)setVolume:(double)volume {
  _player.volume = (float)((volume < 0.0) ? 0.0 : ((volume > 1.0) ? 1.0 : volume));
}

- (void)setPlaybackSpeed:(double)speed {
  _targetPlaybackSpeed = @(speed);
  [self updatePlayingState];
}

- (FlutterError *_Nullable)onCancelWithArguments:(id _Nullable)arguments {
  _eventSink = nil;
  return nil;
}

- (FlutterError *_Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
  _eventSink = events;
  if (self.player.currentItem.status == AVPlayerItemStatusFailed) {
    [self sendFailedToLoadVideoEvent];
    return nil;
  }
  [self setupEventSinkIfReadyToPlay];
  return nil;
}

/// This method allows you to dispose without touching the event channel. This
/// is useful for the case where the Engine is in the process of deconstruction
/// so the channel is going to die or is already dead.
- (void)disposeSansEventChannel {
  _disposed = YES;
  [self removeKeyValueObservers];

  [self.player replaceCurrentItemWithPlayerItem:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)dispose {
  [self disposeSansEventChannel];
  [_eventChannel setStreamHandler:nil];
}

/// Removes all key-value observers set up for the player.
///
/// This is called from dealloc, so must not use any methods on self.
- (void)removeKeyValueObservers {
    AVPlayerItem *currentItem = _player.currentItem;
    if (currentItem) { // Ensure currentItem exists before trying to remove observers
        @try {
            [currentItem removeObserver:self forKeyPath:@"status" context:statusContext];
            [currentItem removeObserver:self forKeyPath:@"loadedTimeRanges" context:timeRangeContext];
            [currentItem removeObserver:self forKeyPath:@"presentationSize" context:presentationSizeContext];
            [currentItem removeObserver:self forKeyPath:@"duration" context:durationContext];
            [currentItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp" context:playbackLikelyToKeepUpContext];
        } @catch (NSException *exception) {
            // This can happen if an observer was not added for a particular key path,
            // or if the item was already deallocated. Log it, but don't crash.
            NSLog(@"Error removing AVPlayerItem observer: %@", exception.reason);
        }
    }
    if (_player) { // Ensure _player exists before trying to remove observers
        @try {
            [_player removeObserver:self forKeyPath:@"rate" context:rateContext];
        } @catch (NSException *exception) {
            NSLog(@"Error removing AVPlayer observer: %@", exception.reason);
        }
    }
}

@end