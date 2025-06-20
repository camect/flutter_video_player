// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import static androidx.media3.common.Player.REPEAT_MODE_ALL;
import static androidx.media3.common.Player.REPEAT_MODE_OFF;

import android.content.Context;
import android.net.Uri; // Added for Uri
import android.view.Surface;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable; // Added for @Nullable
import androidx.annotation.VisibleForTesting;
import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.MimeTypes; // Add this import
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackParameters;
import androidx.media3.exoplayer.ExoPlayer;
import io.flutter.view.TextureRegistry;

// These imports are from the first snippet and are needed if we were to keep buildMediaSource
// within VideoPlayer, but the new structure suggests MediaSourceFactory is handled externally.
// import androidx.media3.datasource.DataSource;
// import androidx.media3.datasource.DefaultDataSource;
// import androidx.media3.datasource.DefaultHttpDataSource;
// import androidx.media3.exoplayer.source.MediaSource;
// import androidx.media3.exoplayer.source.ProgressiveMediaSource;
// import androidx.media3.exoplayer.hls.HlsMediaSource;
// import androidx.media3.exoplayer.dash.DashMediaSource;
// import androidx.media3.exoplayer.dash.DefaultDashChunkSource;
// import androidx.media3.common.util.Util;
// import androidx.media3.exoplayer.smoothstreaming.SsMediaSource;
// import androidx.media3.exoplayer.smoothstreaming.DefaultSsChunkSource;
import java.util.Map; // Added for Map

final class VideoPlayer {
  private ExoPlayer exoPlayer;
  private Surface surface;
  private final TextureRegistry.SurfaceTextureEntry textureEntry;
  private final VideoPlayerCallbacks videoPlayerEvents;
  private final VideoPlayerOptions options;

  // Constants from the first snippet, useful for MediaItem.Builder if formatHint is used.
  private static final String FORMAT_SS = "ss";
  private static final String FORMAT_DASH = "dash";
  private static final String FORMAT_HLS = "hls";
  private static final String FORMAT_OTHER = "other";
  private static final String USER_AGENT = "User-Agent"; // Not directly used in the new update, but kept for context if needed elsewhere.

  /**
   * Creates a video player.
   *
   * @param context application context.
   * @param events event callbacks.
   * @param textureEntry texture to render to.
   * @param asset asset to play.
   * @param options options for playback.
   * @return a video player instance.
   */
  @NonNull
  static VideoPlayer create(
      Context context,
      VideoPlayerCallbacks events,
      TextureRegistry.SurfaceTextureEntry textureEntry,
      VideoAsset asset,
      VideoPlayerOptions options) {
    ExoPlayer.Builder builder =
        new ExoPlayer.Builder(context).setMediaSourceFactory(asset.getMediaSourceFactory(context));
    return new VideoPlayer(builder, events, textureEntry, asset.getMediaItem(), options);
  }

  @VisibleForTesting
  VideoPlayer(
      ExoPlayer.Builder builder,
      VideoPlayerCallbacks events,
      TextureRegistry.SurfaceTextureEntry textureEntry,
      MediaItem mediaItem,
      VideoPlayerOptions options) {
    this.videoPlayerEvents = events;
    this.textureEntry = textureEntry;
    this.options = options;

    ExoPlayer exoPlayer = builder.build();
    exoPlayer.setMediaItem(mediaItem);
    exoPlayer.prepare();

    setUpVideoPlayer(exoPlayer);
  }

  private void setUpVideoPlayer(ExoPlayer exoPlayer) {
    this.exoPlayer = exoPlayer;

    surface = new Surface(textureEntry.surfaceTexture());
    exoPlayer.setVideoSurface(surface);
    setAudioAttributes(exoPlayer, options.mixWithOthers);
    exoPlayer.addListener(new ExoPlayerEventListener(exoPlayer, videoPlayerEvents));
  }

  void sendBufferingUpdate() {
    videoPlayerEvents.onBufferingUpdate(exoPlayer.getBufferedPosition());
  }

  private static void setAudioAttributes(ExoPlayer exoPlayer, boolean isMixMode) {
    exoPlayer.setAudioAttributes(
        new AudioAttributes.Builder().setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
        !isMixMode);
  }

  /**
   * Updates the video player to play a new data source.
   *
   * @param dataSource The URI of the new media.
   * @param formatHint An optional hint about the media format (e.g., "hls", "dash"). Can be null.
   * This hint is used to set the MimeType of the MediaItem.
   * HTTP headers are now expected to be handled by the MediaSourceFactory
   * provided during player creation via VideoAsset.
   */
void update(
      String dataSource,
      @Nullable String formatHint) { // Removed Context and Map<String, String> httpHeaders
    Uri uri = Uri.parse(dataSource);

    // Build the new MediaItem.
    // The MediaSourceFactory set during player creation will handle the actual source building
    // based on the MediaItem's URI and MimeType.
    MediaItem.Builder mediaItemBuilder = new MediaItem.Builder().setUri(uri);

    if (formatHint != null) {
      @Nullable String mimeType = null;
      switch (formatHint) {
        case FORMAT_SS:
          mimeType = MimeTypes.APPLICATION_SS; // Corrected: Use MimeTypes.APPLICATION_SS
          break;
        case FORMAT_DASH:
          mimeType = MimeTypes.APPLICATION_MPD; // Corrected: Use MimeTypes.APPLICATION_MPD
          break;
        case FORMAT_HLS:
          mimeType = MimeTypes.APPLICATION_M3U8; // Corrected: Use MimeTypes.APPLICATION_M3U8
          break;
        case FORMAT_OTHER:
          // For "other", ExoPlayer's inferContentType will usually handle it,
          // but we can explicitly set a generic video mime type if necessary.
          // For simplicity, we'll let ExoPlayer infer if it's "other" and no specific MIME is known.
          // Or, you could default to C.MimeTypes.VIDEO_UNKNOWN if you want to be more explicit.
          break;
        default:
          // Unknown formatHint, let ExoPlayer infer.
          break;
      }
      if (mimeType != null) {
        mediaItemBuilder.setMimeType(mimeType);
      }
    }

    MediaItem newMediaItem = mediaItemBuilder.build();

    exoPlayer.stop(); // Stop current playback
    exoPlayer.setMediaItem(newMediaItem); // Set the new media item
    exoPlayer.prepare(); // Prepare the new media
    exoPlayer.setPlayWhenReady(true); // Start playback of the new media
  }

  void play() {
    exoPlayer.setPlayWhenReady(true);
  }

  void pause() {
    exoPlayer.setPlayWhenReady(false);
  }

  void setLooping(boolean value) {
    exoPlayer.setRepeatMode(value ? REPEAT_MODE_ALL : REPEAT_MODE_OFF);
  }

  void setVolume(double value) {
    float bracketedValue = (float) Math.max(0.0, Math.min(1.0, value));
    exoPlayer.setVolume(bracketedValue);
  }

  void setPlaybackSpeed(double value) {
    // We do not need to consider pitch and skipSilence for now as we do not handle them and
    // therefore never diverge from the default values.
    final PlaybackParameters playbackParameters = new PlaybackParameters(((float) value));

    exoPlayer.setPlaybackParameters(playbackParameters);
  }

  void seekTo(int location) {
    exoPlayer.seekTo(location);
  }

  long getPosition() {
    return exoPlayer.getCurrentPosition();
  }

  void dispose() {
    textureEntry.release();
    if (surface != null) {
      surface.release();
    }
    if (exoPlayer != null) {
      exoPlayer.release();
    }
  }
}