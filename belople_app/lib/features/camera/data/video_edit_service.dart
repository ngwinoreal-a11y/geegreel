import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

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
    } catch (_) {
      return videoPath;
    }
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
    } catch (_) {}
    return (null, null);
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
