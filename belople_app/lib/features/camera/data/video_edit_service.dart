import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

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

/// Applies the step-2 edits — a centre crop to a chosen aspect and/or a burnt-in
/// text overlay — in a single FFmpeg pass (audio is stream-copied, so a prior
/// sound mix is preserved). Returns the edited file, or [videoPath] unchanged
/// when there's nothing to do or on any failure.
class VideoEditService {
  /// [cropAspect] is null/'original' (no crop) or 'w:h' (e.g. '9:16','1:1','4:5').
  /// [text] empty means no overlay. [textPos] is 'top' | 'center' | 'bottom'.
  static Future<String> applyEdits({
    required String videoPath,
    String? cropAspect,
    String text = '',
    String textPos = 'bottom',
  }) async {
    final wantCrop = cropAspect != null && cropAspect != 'original';
    final wantText = text.trim().isNotEmpty;
    if (!wantCrop && !wantText) return videoPath;

    try {
      final (w, h) = await _dims(videoPath);
      if (w == null || h == null) return videoPath;

      // Centre-crop dimensions.
      var cw = w, ch = h, cx = 0, cy = 0;
      if (wantCrop) {
        final parts = cropAspect.split(':');
        final ar = double.parse(parts[0]) / double.parse(parts[1]);
        if (w / h > ar) {
          cw = (h * ar).round();
          cx = (w - cw) ~/ 2;
        } else {
          ch = (w / ar).round();
          cy = (h - ch) ~/ 2;
        }
        cw -= cw.isOdd ? 1 : 0;
        ch -= ch.isOdd ? 1 : 0;
      }

      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final out = '${dir.path}/belople_edited_$stamp.mp4';

      final filter = StringBuffer();
      var vlabel = '[0:v]';
      if (wantCrop) {
        filter.write('[0:v]crop=$cw:$ch:$cx:$cy[c];');
        vlabel = '[c]';
      }

      final inputs = <String>['-i', videoPath];
      if (wantText) {
        final textPath = '${dir.path}/belople_txt_$stamp.png';
        await _writePng(textPath, await _textImage(text.trim(), cw));
        inputs.addAll(['-i', textPath]);
        const m = 28;
        final y = switch (textPos) { 'top' => '$m', 'center' => '(H-h)/2', _ => 'H-h-$m' };
        filter.write("$vlabel[1:v]overlay=(W-w)/2:$y[vout]");
      } else {
        // Crop only — expose the cropped stream as [vout].
        filter.write('${vlabel}null[vout]');
      }

      final args = [
        '-y', ...inputs,
        '-filter_complex', filter.toString(),
        '-map', '[vout]', '-map', '0:a?',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '23', '-pix_fmt', 'yuv420p',
        '-c:a', 'copy', '-movflags', '+faststart', out,
      ];

      final completer = Completer<bool>();
      await FFmpegKit.executeWithArgumentsAsync(args, (s) async {
        final rc = await s.getReturnCode();
        if (!completer.isCompleted) completer.complete(ReturnCode.isSuccess(rc));
      });
      final ok = await completer.future.timeout(const Duration(seconds: 240), onTimeout: () {
        FFmpegKit.cancel();
        return false;
      });
      return (ok && File(out).existsSync()) ? out : videoPath;
    } catch (e) {
      // The clip itself survives — the edits are what's lost — but the reason
      // goes to the log rather than disappearing with them.
      debugPrint('[BLEDIT] applyEdits failed, publishing the clip unedited: $e');
      return videoPath;
    }
  }

  /// Burns a colour look — [chain] from `CameraFilter.ffmpegChain` — into the
  /// picture, so the published file carries what the viewfinder showed. The
  /// audio is stream-copied, so a sound mixed in earlier survives untouched and
  /// this is the only pass that re-encodes the picture.
  ///
  /// Throws [VideoEditFailure] instead of handing back the untouched clip: a
  /// look that quietly doesn't apply is the exact bug this exists to fix, and
  /// the caller has to be able to tell the difference.
  static Future<String> applyColourChain({
    required String videoPath,
    required String chain,
    void Function(double progress)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final out = '${dir.path}/belople_look_${DateTime.now().millisecondsSinceEpoch}.mp4';

    // Progress is FFmpeg's position in the clip over the clip's length. Without
    // a length there's nothing to divide by, so the bar just stays put rather
    // than inventing a number.
    final totalMs = await _durationMs(videoPath);

    final args = [
      '-y', '-i', videoPath,
      '-vf', chain,
      '-map', '0:v', '-map', '0:a?',
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
      throw VideoEditFailure(
        timedOut ? 'the colour pass timed out after 6 minutes' : 'the colour pass failed',
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

  /// White, wrapped, shadowed text on transparent, [width] px wide.
  static Future<ui.Image> _textImage(String text, int width) async {
    final scale = (width / 720).clamp(0.7, 2.2);
    final size = 34.0 * scale;
    const pad = 18.0;
    final maxTextWidth = width - pad * 2;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white,
          fontSize: size,
          fontWeight: FontWeight.w700,
          height: 1.2,
          shadows: const [Shadow(color: Colors.black, blurRadius: 6, offset: Offset(0, 1))],
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 4,
      ellipsis: '…',
    )..layout(maxWidth: maxTextWidth);

    final imgW = width;
    final imgH = (painter.height + pad * 2).ceil();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paint(canvas, Offset((imgW - painter.width) / 2, pad));
    return recorder.endRecording().toImage(imgW, imgH);
  }

  static Future<void> _writePng(String path, ui.Image image) async {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('png encode failed');
    await File(path).writeAsBytes(bytes.buffer.asUint8List());
  }
}
