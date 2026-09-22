import 'dart:typed_data';

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/origins.dart';
import 'package:aves_video/aves_video.dart';
import 'package:image/image.dart' as img;
import 'package:nsfw_detector_flutter/nsfw_detector_flutter.dart';

/// Strict pre-playback policy for avesnovid.
///
/// The gate is intentionally local and fail-closed: media is never uploaded,
/// and a video is never started before this check returns.
class VideoScreeningService {
  static const int maxDurationMillis = 5 * 60 * 1000;
  static const double nsfwThreshold = .70;

  static final Map<String, VideoScreeningResult> _cache = {};

  static Future<VideoScreeningResult> screen(
    AvesEntry entry,
    AvesVideoController controller,
  ) async {
    final key = '\${entry.uri}|\${entry.dateModifiedMillis}|\${entry.sizeBytes}|\${entry.durationMillis}';
    final cached = _cache[key];
    if (cached != null) return cached;

    final basic = _screenMetadata(entry);
    if (!basic.allowed) return _remember(key, basic);

    try {
      await controller.untilReady;

      final textTracks = controller.tracks.where((t) => t.type == MediaTrackType.text).length;
      final audioTracks = controller.tracks.where((t) => t.type == MediaTrackType.audio).length;
      if (textTracks > 0) return _remember(key, const VideoScreeningResult.blocked('subtitle-track'));
      if (audioTracks > 1) return _remember(key, const VideoScreeningResult.blocked('multiple-audio-tracks'));

      final times = <int>{
        0,
        (controller.duration * .33).round(),
        (controller.duration * .66).round(),
        (controller.duration - 250).clamp(0, controller.duration).toInt(),
      }.toList()
        ..sort();

      final frames = <Uint8List>[];
      for (final time in times) {
        await controller.seekTo(time);
        await Future<void>.delayed(const Duration(milliseconds: 90));
        final frame = await controller.captureFrame();
        if (frame != null && frame.isNotEmpty) frames.add(frame);
      }

      if (frames.isEmpty) {
        return _remember(key, const VideoScreeningResult.blocked('unable-to-screen'));
      }

      for (final frame in frames) {
        final result = await NsfwDetector.detectBytesInBackground(
          frame,
          threshold: nsfwThreshold,
        );
        if (result?.isNsfw == true) {
          return _remember(key, const VideoScreeningResult.blocked('adult-content'));
        }
      }

      var largeChanges = 0;
      for (var i = 1; i < frames.length; i++) {
        if (_frameDifference(frames[i - 1], frames[i]) > .58) largeChanges++;
      }
      if (largeChanges >= 2) {
        return _remember(key, const VideoScreeningResult.blocked('rapid-scene-changes'));
      }

      return _remember(key, const VideoScreeningResult.allowed());
    } catch (_) {
      return _remember(key, const VideoScreeningResult.blocked('screening-error'));
    }
  }

  static VideoScreeningResult _screenMetadata(AvesEntry entry) {
    final duration = entry.durationMillis ?? 0;
    if (duration <= 0 || duration > maxDurationMillis) {
      return const VideoScreeningResult.blocked('over-five-minutes');
    }

    if (entry.origin != EntryOrigins.mediaStoreContent || entry.sourceDateTakenMillis == null) {
      return const VideoScreeningResult.blocked('not-camera-origin');
    }

    final path = entry.path?.replaceAll('\\', '/').toLowerCase();
    if (path == null || !_looksLikeCameraPath(path)) {
      return const VideoScreeningResult.blocked('outside-camera-folder');
    }

    final name = (entry.fileNameWithoutExtension ?? '').toLowerCase();
    const rejectTokens = <String>{
      'download', 'youtube', 'tiktok', 'instagram', 'facebook', 'telegram',
      'whatsapp', 'movie', 'trailer', 'episode', 'netflix', 'screenrecord',
      'screen_record', 'screencap', 'reel', 'shorts',
    };
    if (rejectTokens.any(name.contains)) {
      return const VideoScreeningResult.blocked('external-clip-name');
    }

    return const VideoScreeningResult.allowed();
  }

  static bool _looksLikeCameraPath(String path) {
    final camera = RegExp(
      r'/dcim/(camera|100[a-z0-9_-]+|[0-9]{3}[a-z0-9_-]*)/',
      caseSensitive: false,
    );
    return camera.hasMatch(path) || path.contains('/movies/camera/');
  }

  static double _frameDifference(Uint8List a, Uint8List b) {
    final ia = img.decodeImage(a);
    final ib = img.decodeImage(b);
    if (ia == null || ib == null) return 1;

    final ra = img.copyResize(ia, width: 16, height: 16, interpolation: img.Interpolation.average);
    final rb = img.copyResize(ib, width: 16, height: 16, interpolation: img.Interpolation.average);

    var total = 0.0;
    for (var y = 0; y < 16; y++) {
      for (var x = 0; x < 16; x++) {
        final pa = ra.getPixel(x, y);
        final pb = rb.getPixel(x, y);
        final la = .299 * pa.r + .587 * pa.g + .114 * pa.b;
        final lb = .299 * pb.r + .587 * pb.g + .114 * pb.b;
        total += (la - lb).abs() / 255;
      }
    }
    return total / 256;
  }

  static VideoScreeningResult _remember(String key, VideoScreeningResult result) {
    _cache[key] = result;
    return result;
  }
}

class VideoScreeningResult {
  final bool allowed;
  final String? reason;

  const VideoScreeningResult._(this.allowed, this.reason);

  const VideoScreeningResult.allowed() : this._(true, null);

  const VideoScreeningResult.blocked(String reason) : this._(false, reason);
}
