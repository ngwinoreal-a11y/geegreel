import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'video_text_overlay.dart';

/// A render pass that did not produce a file. Carries FFmpeg's own tail so the
/// reason is in the log rather than lost — the caller decides what to tell the
/// person waiting, but it is never nothing.
class VideoEditFailure implements Exception {
  VideoEditFailure(this.message, {this.log});
  final String message;
  final String? log;

  @override
  String toString() => 'VideoEditFailure: $message${log == null ? '' : '\n$log'}';
}

/// The passes that turn what the composer showed into what the file carries.
class VideoEditService {
  /// Burns the look and the text overlays into the picture in ONE pass, so the
  /// published file carries what the preview promised. [chain] comes from
  /// `CameraFilter.ffmpegChain`; [overlayPngPath] is a transparent PNG the size
  /// of the frame, from [renderOverlayPng]. Either may be null; both null is a
  /// caller bug and throws rather than quietly re-encoding for nothing.
  ///
  /// One pass matters. This is the only place a published clip is re-encoded —
  /// the sound mix copies the picture and rebuilds the audio — so burning text
  /// in a second pass would put every posted video through a second generation
  /// of h264 to add a caption.
  ///
  /// Throws [VideoEditFailure] instead of handing back the untouched clip: an
  /// edit that quietly doesn't apply is the exact bug this exists to fix, and
  /// the caller has to be able to tell the difference.
  static Future<String> burnIn({
    required String videoPath,
    String? chain,
    String? overlayPngPath,
    void Function(double progress)? onProgress,
  }) async {
    if (chain == null && overlayPngPath == null) {
      throw VideoEditFailure('burnIn was called with nothing to burn in');
    }
    final dir = await getTemporaryDirectory();
    final out = '${dir.path}/belople_look_${DateTime.now().millisecondsSinceEpoch}.mp4';

    // Progress is FFmpeg's position in the clip over the clip's length. Without
    // a length there's nothing to divide by, so the bar just stays put rather
    // than inventing a number.
    final totalMs = await _durationMs(videoPath);

    // The overlay is a second input, composited over whatever the colour chain
    // produced. scale2ref forces the PNG to the frame's exact size before it
    // lands: the PNG is rendered at the size the PREVIEW was showing, and a
    // clip with rotation metadata reaches the filter graph already turned
    // upright, so the two agree on which side is up but not necessarily on the
    // pixel count. Stretching a picture that already has the right aspect ratio
    // costs nothing; landing the text in the wrong place costs everything.
    final overlay = overlayPngPath != null;
    final filterArgs = overlay
        ? [
            '-filter_complex',
            [
              if (chain != null) '[0:v]$chain[g];' else '[0:v]null[g];',
              '[1:v][g]scale2ref=w=iw:h=ih[ov][base];',
              '[base][ov]overlay=0:0:format=auto[vout]',
            ].join(),
            '-map', '[vout]',
          ]
        : ['-vf', chain!, '-map', '0:v'];

    final args = [
      '-y', '-i', videoPath,
      if (overlay) ...['-i', overlayPngPath],
      ...filterArgs,
      '-map', '0:a?',
      // This is the ONE re-encode a published clip goes through, so it is the
      // one place its quality can be lost. veryfast/crf 20 keeps the grade
      // clean where the old ultrafast/crf 23 left blocking in the shadows —
      // exactly where a Fade or a Noir puts the eye. maxrate caps what crf
      // alone won't: a busy handheld shot at crf 20 can run to several times
      // the size of the original, which someone on mobile data then has to
      // upload and everyone else has to stream.
      '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
      '-maxrate', '8M', '-bufsize', '16M', '-pix_fmt', 'yuv420p',
      '-c:a', 'copy', '-movflags', '+faststart', out,
    ];

    final completer = Completer<bool>();
    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (s) async {
        final rc = await s.getReturnCode();
        if (!completer.isCompleted) completer.complete(ReturnCode.isSuccess(rc));
      },
      null,
      (stats) {
        if (totalMs == null || totalMs <= 0 || onProgress == null) return;
        onProgress((stats.getTime() / totalMs).clamp(0.0, 1.0));
      },
    );

    var timedOut = false;
    final ok = await completer.future.timeout(const Duration(minutes: 6), onTimeout: () {
      timedOut = true;
      FFmpegKit.cancel();
      return false;
    });

    if (!ok || !File(out).existsSync()) {
      // Read the log back off the session — FFmpeg's own last words are the
      // only thing that ever explains one of these.
      String? log;
      try {
        final all = await session.getAllLogsAsString(2000);
        log = all?.substring(all.length > 4000 ? all.length - 4000 : 0);
      } catch (e) {
        log = 'could not read the FFmpeg log: $e';
      }
      // Name what was actually being burnt in. "The colour pass failed" on a
      // clip with no look picked sent the last reader looking in the wrong
      // place entirely.
      final what = chain != null && overlay ? 'the look and text pass'
                 : overlay ? 'the text pass'
                 : 'the colour pass';
      throw VideoEditFailure(
        timedOut ? '$what timed out after 6 minutes' : '$what failed',
        log: log,
      );
    }
    onProgress?.call(1);
    return out;
  }

  static Future<(int?, int?)> _dims(String path) async {
    try {
      final info = (await FFprobeKit.getMediaInformation(path)).getMediaInformation();
      final streams = info?.getStreams();
      if (streams != null) {
        for (final s in streams) {
          if (s.getType() == 'video') return (s.getWidth(), s.getHeight());
        }
      }
    } catch (e) {
      debugPrint('[BLEDIT] could not probe dimensions of $path: $e');
    }
    return (null, null);
  }

  /// Clip length in milliseconds, or null when ffprobe can't say. Only the
  /// progress bar depends on it, so null is survivable.
  static Future<int?> _durationMs(String path) async {
    try {
      final info = (await FFprobeKit.getMediaInformation(path)).getMediaInformation();
      final seconds = double.tryParse(info?.getDuration() ?? '');
      return seconds == null ? null : (seconds * 1000).round();
    } catch (e) {
      debugPrint('[BLEDIT] could not probe duration of $path: $e');
      return null;
    }
  }

  /// Draws every overlay onto one transparent PNG the size of the frame, and
  /// returns its path — or null when there is nothing to draw.
  ///
  /// One picture for all of them, not one per overlay: FFmpeg would otherwise
  /// need an input and an overlay filter per piece of text, and the graph grows
  /// with something the poster controls.
  ///
  /// [displaySize] is the size the PREVIEW was showing — `VideoPlayerController
  /// .value.size`, which already has any rotation metadata applied. It is what
  /// the finger was pointing at, so it is what the text is placed against. When
  /// it is missing, ffprobe answers instead.
  static Future<String?> renderOverlayPng({
    required List<VideoTextOverlay> overlays,
    required String videoPath,
    Size? displaySize,
  }) async {
    final wanted = overlays.where((o) => !o.isEmpty).toList();
    if (wanted.isEmpty) return null;

    var w = displaySize?.width.round() ?? 0;
    var h = displaySize?.height.round() ?? 0;
    if (w <= 0 || h <= 0) {
      final (pw, ph) = await _dims(videoPath);
      w = pw ?? 0;
      h = ph ?? 0;
    }
    if (w <= 0 || h <= 0) {
      throw VideoEditFailure('could not work out the video size to place the text on');
    }

    final frame = Size(w.toDouble(), h.toDouble());
    final recorder = ui.PictureRecorder();
    // The very painter the composer's preview draws with, at the file's size
    // instead of the screen's. Not a second implementation that has to be kept
    // in step with it — the same one.
    OverlayLayerPainter(wanted).paint(Canvas(recorder, Offset.zero & frame), frame);
    final image = await recorder.endRecording().toImage(w, h);

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/belople_text_${DateTime.now().millisecondsSinceEpoch}.png';
    await _writePng(path, image);
    debugPrint('[BLEDIT] rendered ${wanted.length} text overlay(s) at ${w}x$h -> $path');
    return path;
  }

  static Future<void> _writePng(String path, ui.Image image) async {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('png encode failed');
    await File(path).writeAsBytes(bytes.buffer.asUint8List());
  }
}
