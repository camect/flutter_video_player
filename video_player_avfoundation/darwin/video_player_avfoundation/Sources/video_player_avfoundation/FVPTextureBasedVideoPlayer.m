// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "./include/video_player_avfoundation/FVPTextureBasedVideoPlayer.h"
#import "./include/video_player_avfoundation/FVPTextureBasedVideoPlayer_Test.h"

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
@end

@implementation FVPTextureBasedVideoPlayer
- (instancetype)initWithAsset:(NSString *)asset
                 frameUpdater:(FVPFrameUpdater *)frameUpdater
                  displayLink:(FVPDisplayLink *)displayLink
                    avFactory:(id<FVPAVFactory>)avFactory
                    registrar:(NSObject<FlutterPluginRegistrar> *)registrar
                   onDisposed:(void (^)(int64_t))onDisposed {
  // Initialize with a file URL derived from the asset name.
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
  // Prepare options for AVURLAsset, including HTTP headers if provided.
  NSDictionary<NSString *, id> *options = nil;
  if ([headers count] != 0) {
    options = @{@"AVURLAssetHTTPHeaderFieldsKey" : headers};
  }
  // Create an AVURLAsset from the URL and options.
  AVURLAsset *urlAsset = [AVURLAsset URLAssetWithURL:url options:options];
  AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:urlAsset];
  // Initialize with the created AVPlayerItem.
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
  // Call superclass initializer (FVPVideoPlayer).
  self = [super initWithPlayerItem:item avFactory:avFactory registrar:registrar];

  if (self) {
    _frameUpdater = frameUpdater;     // Store the frame updater.
    _displayLink = displayLink;       // Store the display link.
    _frameUpdater.displayLink = _displayLink; // Link display link to frame updater.
    _selfRefresh = true;              // Enable self-refreshing behavior for copyPixelBuffer.
    _onDisposed = [onDisposed copy];  // Store the dispose callback.

    // This is to fix 2 bugs: 1. blank video for encrypted video streams on iOS 16
    // (https://github.com/flutter/flutter/issues/111457) and 2. swapped width and height for some
    // video streams (not just iOS 16).  (https://github.com/flutter/flutter/issues/109116). An
    // invisible AVPlayerLayer is used to overwrite the protection of pixel buffers in those streams
    // for issue #1, and restore the correct width and height for issue #2.
    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    // Add the player layer as a sublayer to the Flutter view's layer.
    [self.flutterViewLayer addSublayer:self.playerLayer];
  }
  return self;
}

- (void)updateWithFile:(NSString *)filePath {
  // Create a new AVPlayerItem from the new file path.
  NSURL *fileURL = [NSURL fileURLWithPath:filePath];
  AVURLAsset *urlAsset = [AVURLAsset URLAssetWithURL:fileURL options:nil];
  AVPlayerItem *newItem = [AVPlayerItem playerItemWithAsset:urlAsset];

  // Store the old item before replacing it.
  AVPlayerItem *oldItem = self.player.currentItem;

  // IMPORTANT: Remove observers from the OLD item before replacing it.
  // This calls the method in the superclass (FVPVideoPlayer) that correctly removes
  // all KVO and notification observers associated with `oldItem`.
  [self removeObserversFromPlayerItem:oldItem player:self.player];

  // Replace the current player item with the new one.
  [self.player replaceCurrentItemWithPlayerItem:newItem];

  // IMPORTANT: Add observers to the NEW item after it has been set.
  // This calls the method in the superclass (FVPVideoPlayer) that correctly adds
  // all KVO and notification observers associated with `newItem`.
  [self addObserversToPlayerItem:newItem player:self.player];

  // Re-attach the player to the layer. This is generally redundant if the `_player` object
  // itself doesn't change, but harmless.
  self.playerLayer.player = self.player;

  // Reset internal state for the new video.
  CVBufferRelease(self.latestPixelBuffer); // Release old pixel buffer.
  self.latestPixelBuffer = nil;
  self.waitingForFrame = YES;      // Expect a new frame.
  self.displayLink.running = YES;  // Ensure display link is running to get the new frame.
  [self expectFrame];              // Signal expectation of a new frame.
  self.selfRefresh = true;         // Re-enable self-refresh for copyPixelBuffer.
}

// This method was an empty placeholder in the original FVPTextureBasedVideoPlayer.m.
// It is now removed as the superclass (FVPVideoPlayer) provides the necessary
// `removeObserversFromPlayerItem:player:` method which is called directly in `updateWithFile:`.
/*
- (void)removeObserversFromPlayerItem:(AVPlayerItem *)item {
    if (!item) return;
    // ... This method was empty, now handled by superclass
}
*/

- (void)dealloc {
  // The superclass's `dealloc` will call `removeKeyValueObservers`, which now correctly
  // handles cleanup of the current AVPlayerItem and AVPlayer.
  CVBufferRelease(_latestPixelBuffer); // Release the latest pixel buffer.
}

- (void)setTextureIdentifier:(int64_t)textureIdentifier {
  self.frameUpdater.textureIdentifier = textureIdentifier;
}

- (void)expectFrame {
  self.waitingForFrame = YES; // Mark that we are waiting for a frame.

  _displayLink.running = YES; // Ensure the display link is running.
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
  // On iOS, get the root view controller's view layer.
  UIViewController *root = UIApplication.sharedApplication.keyWindow.rootViewController;
#pragma clang diagnostic pop
  return root.view.layer;
#endif
}

#pragma mark - Overrides

- (void)updatePlayingState {
  [super updatePlayingState]; // Call superclass implementation to update player's state.
  // If the texture is still waiting for an expected frame, the display link needs to keep
  // running until it arrives regardless of the play/pause state.
  _displayLink.running = self.isPlaying || self.waitingForFrame;
}

- (void)seekTo:(int64_t)location completionHandler:(void (^)(BOOL))completionHandler {
  CMTime previousCMTime = self.player.currentTime; // Store current time before seeking.
  [super seekTo:location
      completionHandler:^(BOOL completed) {
        // If the seek actually resulted in a time change.
        if (CMTimeCompare(self.player.currentTime, previousCMTime) != 0) {
          // Ensure that a frame is drawn once available, even if currently paused.
          // This uses the display link because the pixel buffer might not be immediately available
          // after the seek completes.
          [self expectFrame];
        }

        if (completionHandler) {
          completionHandler(completed); // Call the original completion handler.
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

  [super disposeSansEventChannel]; // Call superclass dispose.

  [self.playerLayer removeFromSuperlayer]; // Remove the AVPlayerLayer from its superlayer.

  _displayLink = nil; // Release the display link.
}

- (void)dispose {
  [super dispose]; // Call superclass dispose.

  // Execute the onDisposed callback with the texture identifier.
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
    self.targetTime = currentTime; // Reset target time if significantly off.
  }
  self.targetTime += duration; // Advance target time by frame duration.

  CVPixelBufferRef buffer = NULL;
  CMTime outputItemTime = [self.videoOutput itemTimeForHostTime:self.targetTime];
  // Check if a new pixel buffer is available for the target time.
  if ([self.videoOutput hasNewPixelBufferForItemTime:outputItemTime]) {
    // Copy the pixel buffer and release the old one.
    buffer = [self.videoOutput copyPixelBufferForItemTime:outputItemTime itemTimeForDisplay:NULL];
    if (buffer) {
      CVBufferRelease(self.latestPixelBuffer); // Release the old buffer.
      self.latestPixelBuffer = buffer; // Store the new buffer.
    }
  }

  // If we were waiting for a frame and a new buffer is now available.
  if (self.waitingForFrame && buffer) {
    self.waitingForFrame = NO; // No longer waiting.
    // If the display link was only running temporarily (e.g., after a seek while paused), stop it.
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

    // Reset measurement if duration has significantly changed.
    if (fabs(duration - self.latestDuration) >= self.latestDuration * resetFraction) {
      self.startTime = currentTime;
      self.framesCount = 0;
      self.latestDuration = duration;
    }
    // Perform check after windowSize frames.
    if (self.framesCount == windowSize) {
      CFTimeInterval averageDuration = (currentTime - self.startTime) / windowSize;
      if (averageDuration < duration * durationThreshold) {
        NSLog(@"Warning: measured average duration between frames is unexpectedly short (%f/%f), "
              @"please report this to "
              @"https://github.com/flutter/flutter/issues.",
              averageDuration, duration);
        self.selfRefresh = false; // Disable self-refresh if average duration is too short.
      }
      self.startTime = currentTime; // Reset start time for next window.
      self.framesCount = 0; // Reset frame count.
    }
    self.framesCount++; // Increment frame count.

    // Dispatch textureFrameAvailable to the main queue.
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
    // Dispose the player if it hasn't been disposed already.
    if (!self.disposed) {
      [self dispose];
    }
  });
}

@end
