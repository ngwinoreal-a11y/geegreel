import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Brands a video *for download only*: burns in a moving Belople watermark
/// (play mark + "Belople" + the poster's @username, jumping between corners
/// TikTok-style) and appends a short branded outro. Nothing here runs on the
/// in-app player — the app plays the clean source; only the saved file carries
/// the marks, so a re-shared clip advertises where it came from.
///
/// Every failure path returns the ORIGINAL [sourcePath] so a download still
/// succeeds (just unbranded) rather than failing outright.
class VideoWatermarkService {
  /// Bundled outro clip appended to every download (kept whole, with its own
  /// audio). Fallback duration is only used if probing the clip fails.
  static const _outroAsset = 'assets/video/outro.mp4';
  static const _outroFallbackSeconds = 2;

  /// How long the watermark rests in one spot before hopping (seconds).

  /// Longest output edge — bigger videos are scaled down to this so the
  /// on-device re-encode finishes in reasonable time (the watermark/outro
  /// stay legible at this size).
  static const _maxDimension = 960;

  /// Hard ceiling on the encode so a pathological video can never leave the
  /// UI stuck on "Finishing" forever — past this we cancel and save unbranded.
  static const _timeout = Duration(seconds: 300);

  /// [onProgress] reports 0..1 during the encode so the UI can show a live
  /// percentage instead of a frozen-looking "Finishing".
  static Future<String> brandForDownload({
    required String sourcePath,
    required String username,
    int? width,
    int? height,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final probe = await _probe(sourcePath);
      final srcW = width ?? probe.width;
      final srcH = height ?? probe.height;
      final dur = probe.durationSeconds;
      // Need real dimensions AND duration: dimensions to build a matching
      // outro, duration to bound the watermark input so FFmpeg terminates
      // (an unbounded looped overlay image hangs the encode forever). Missing
      // either → skip branding and save the clean video rather than risk a hang.
      if (srcW == null || srcH == null || srcW <= 0 || srcH <= 0) return await _ensureMp4(sourcePath, width: width, height: height);
      if (dur == null || dur <= 0) return await _ensureMp4(sourcePath, width: width, height: height);

      // Cap resolution (even numbers — x264 requires them) to keep the encode fast.
      final (w, h) = _capped(srcW, srcH);

      // The user-supplied outro clip (kept whole, with its own sound).
      final outro = await _outroInfo();

      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final wmPath = '${dir.path}/bl_wm_$stamp.png';
      final m1 = '${dir.path}/bl_m1_$stamp.mp4'; // watermarked main
      final m2 = '${dir.path}/bl_m2_$stamp.mp4'; // normalised outro
      final listPath = '${dir.path}/bl_list_$stamp.txt';
      final outPath = '${dir.path}/belople_branded_$stamp.mp4';

      await _writePng(wmPath, await _watermarkImage(username, w));

      // Two-pass, then a copy-concat — this is what kills the silent/frozen gap
      // between the video and the outro. FFmpeg's format duration is the max of
      // all streams, so a video whose audio track runs longer (or shorter) than
      // the picture (common in webm) would otherwise freeze/pad the tail before
      // the outro. `-shortest` in pass 1 clamps the watermarked main to the
      // shorter of picture/sound, so the outro follows the instant the content
      // ends. Both clips are normalised to identical params so pass 3 can
      // stitch them with `-c copy` (near-instant, no re-encode of the main).
      final ok1 = await _run(
        _pass1Args(input: sourcePath, watermark: wmPath, output: m1, w: w, h: h,
            hasAudio: probe.hasAudio, wmDuration: (dur + 2).ceil()),
        totalMs: dur * 1000,
        onProgress: onProgress,
      );
      if (ok1) await _run(_pass2Args(outro: outro.path, output: m2, w: w, h: h, outroHasAudio: outro.hasAudio));

      var joined = false;
      if (ok1 && File(m1).existsSync() && File(m2).existsSync()) {
        await File(listPath).writeAsString("file '$m1'\nfile '$m2'\n");
        joined = await _run(_concatCopyArgs(listPath, outPath));
        // Fallback: if the byte-copy stitch is rejected, re-encode-concat them.
        if (!joined) joined = await _run(_concatFilterArgs(m1, m2, outPath, w, h));
      }

      for (final p in [wmPath, m1, m2, listPath]) {
        _quietDelete(p);
      }

      if (joined && File(outPath).existsSync()) return outPath;
      _quietDelete(outPath);
      // Branding failed — still hand back a REAL mp4 (not the raw .webm the
      // source often is), so the saved file plays and WhatsApp/others accept it.
      return await _ensureMp4(sourcePath, width: width, height: height);
    } catch (_) {
      return await _ensureMp4(sourcePath, width: width, height: height);
    }
  }

  /// Guarantees a valid H.264/AAC MP4 (faststart) — used as the fallback when
  /// the full branding pipeline can't run. Crucially it RE-ENCODES the source
  /// (which is usually .webm) into a real .mp4 while keeping its audio, so the
  /// exact video the user is watching — with the sound that plays in it — is
  /// what lands in the gallery, in a format WhatsApp and every player accept.
  static Future<String> _ensureMp4(String sourcePath, {int? width, int? height}) async {
    try {
      final probe = await _probe(sourcePath);
      final (w, h) = _capped(width ?? probe.width ?? 720, height ?? probe.height ?? 1280);
      final dir = await getTemporaryDirectory();
      final out = '${dir.path}/belople_mp4_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final args = <String>[
        '-y', '-i', sourcePath,
        '-vf', _scaleBase(w, h),
        ..._vEnc,
        // Keep the source audio (the sound that plays) if present; the mapping
        // is optional so a silent clip still transcodes fine.
        if (probe.hasAudio) ...['-map', '0:v:0', '-map', '0:a:0?', ..._aEnc] else ...['-an'],
        '-movflags', '+faststart', out,
      ];
      final ok = await _run(args, totalMs: (probe.durationSeconds ?? 0) * 1000);
      if (ok && File(out).existsSync()) return out;
      _quietDelete(out);
    } catch (_) {}
    return sourcePath; // absolute last resort
  }

  /// Runs one FFmpeg session; resolves true on success, false on failure or if
  /// it blows past [_timeout]. Optional live progress from the statistics time.
  static Future<bool> _run(List<String> args,
      {double? totalMs, void Function(double)? onProgress}) async {
    final completer = Completer<bool>();
    await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        final rc = await session.getReturnCode();
        if (!completer.isCompleted) completer.complete(ReturnCode.isSuccess(rc));
      },
      null,
      (stats) {
        if (totalMs != null && totalMs > 0 && onProgress != null) {
          onProgress((stats.getTime() / totalMs).clamp(0.0, 1.0));
        }
      },
    );
    return completer.future.timeout(_timeout, onTimeout: () {
      FFmpegKit.cancel();
      return false;
    });
  }

  /// Scales (w,h) so the longest edge is at most [_maxDimension], keeping
  /// aspect and forcing even dimensions.
  static (int, int) _capped(int w, int h) {
    var tw = w, th = h;
    final longest = math.max(w, h);
    if (longest > _maxDimension) {
      final s = _maxDimension / longest;
      tw = (w * s).round();
      th = (h * s).round();
    }
    tw -= tw.isOdd ? 1 : 0;
    th -= th.isOdd ? 1 : 0;
    return (math.max(2, tw), math.max(2, th));
  }

  // ---- FFmpeg ----------------------------------------------------------

  // Identical encoder settings for pass 1 and pass 2 so their outputs match
  // exactly and pass 3 can stitch them with `-c copy` (no re-encode).
  static const _vEnc = [
    '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '23',
    '-pix_fmt', 'yuv420p', '-r', '30', '-video_track_timescale', '15360',
  ];
  static const _aEnc = ['-c:a', 'aac', '-ar', '44100', '-ac', '2', '-b:a', '128k'];

  static String _scaleBase(int w, int h) =>
      'scale=$w:$h:force_original_aspect_ratio=decrease,pad=$w:$h:(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=30,format=yuv420p';

  /// Pass 1: burn the moving watermark onto the main video and clamp it with
  /// `-shortest`, so picture and sound end together — that's what removes the
  /// frozen/silent tail that used to sit before the outro. The mark hops
  /// sweeping left-to-right low in the frame.
  static List<String> _pass1Args({
    required String input,
    required String watermark,
    required String output,
    required int w,
    required int h,
    required bool hasAudio,
    required int wmDuration,
  }) {
    const m = 20;
    // A smooth left-to-right sweep, low in the frame — NOT the old six-spot
    // hop. That jumped between corners and the vertical centre, so it kept
    // landing over the middle of the picture (a face, usually) and read as a
    // glitch rather than a mark. abs(mod(t/T,2)-1) is a triangle wave: 0 at
    // the left margin, 1 at the right, and back, with no jump at the turn.
    const sweepSeconds = 9;
    final phase = 'abs(mod(t/$sweepSeconds,2)-1)';
    final xExpr = '$m+($phase)*(W-w-${m * 2})';
    // Held near the bottom edge, clear of the subject, with a small bob so the
    // mark reads as alive rather than pasted on. A few pixels only — the
    // motion the eye follows is still the horizontal sweep.
    final yExpr = 'H-h-${m * 2}+6*sin(t*1.6)';
    final overlay = "overlay=x='$xExpr':y='$yExpr':eval=frame:shortest=1";

    final inputs = <String>[
      '-i', input,
      '-loop', '1', '-t', '$wmDuration', '-i', watermark,
    ];
    String audioMap;
    if (hasAudio) {
      audioMap = '0:a';
    } else {
      inputs.addAll(['-f', 'lavfi', '-t', '$wmDuration', '-i', 'anullsrc=r=44100:cl=stereo']);
      audioMap = '2:a';
    }
    return [
      '-y', ...inputs,
      '-filter_complex', '[0:v]${_scaleBase(w, h)}[v0];[v0][1:v]$overlay[vo]',
      '-map', '[vo]', '-map', audioMap, '-shortest',
      ..._vEnc, ..._aEnc, output,
    ];
  }

  /// Pass 2: re-encode the outro to the exact same params as pass 1.
  static List<String> _pass2Args({
    required String outro,
    required String output,
    required int w,
    required int h,
    required bool outroHasAudio,
  }) {
    final inputs = <String>['-i', outro];
    String audioMap;
    if (outroHasAudio) {
      audioMap = '0:a';
    } else {
      inputs.addAll(['-f', 'lavfi', '-t', '60', '-i', 'anullsrc=r=44100:cl=stereo']);
      audioMap = '1:a';
    }
    return [
      '-y', ...inputs,
      '-filter_complex', '[0:v]${_scaleBase(w, h)}[v]',
      '-map', '[v]', '-map', audioMap, '-shortest',
      ..._vEnc, ..._aEnc, output,
    ];
  }

  /// Pass 3: byte-copy stitch of the two normalised clips (near-instant).
  static List<String> _concatCopyArgs(String listPath, String output) => [
        '-y', '-f', 'concat', '-safe', '0', '-i', listPath,
        '-c', 'copy', '-movflags', '+faststart', output,
      ];

  /// Pass 3 fallback: re-encode-concat if the byte-copy stitch is refused.
  static List<String> _concatFilterArgs(String a, String b, String output, int w, int h) {
    const aF = 'aformat=sample_rates=44100:channel_layouts=stereo,asetpts=PTS-STARTPTS';
    final sb = _scaleBase(w, h);
    final filter =
        '[0:v]$sb,setpts=PTS-STARTPTS[a0];[1:v]$sb,setpts=PTS-STARTPTS[b0];[0:a]$aF[a1];[1:a]$aF[b1];[a0][a1][b0][b1]concat=n=2:v=1:a=1[outv][outa]';
    return [
      '-y', '-i', a, '-i', b,
      '-filter_complex', filter,
      '-map', '[outv]', '-map', '[outa]',
      ..._vEnc, ..._aEnc, '-movflags', '+faststart', output,
    ];
  }

  static Future<_Probe> _probe(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info == null) return const _Probe(null, null, true, null);
      int? w, h;
      var hasAudio = false;
      for (final s in info.getStreams()) {
        final type = s.getType();
        if (type == 'video' && w == null) {
          w = s.getWidth();
          h = s.getHeight();
        } else if (type == 'audio') {
          hasAudio = true;
        }
      }
      final dur = double.tryParse(info.getDuration() ?? '');
      return _Probe(w, h, hasAudio, dur);
    } catch (_) {
      // Assume audio present — if wrong, the concat fails and we fall back to
      // the unbranded original.
      return const _Probe(null, null, true, null);
    }
  }

  // ---- Image generation ------------------------------------------------

  // The logo's own colours (orange → pink) — used for the "Belople" wordmark
  // so the name matches the mark.
  static const _logoOrange = Color(0xFFFF7A00);
  static const _logoPink = Color(0xFFFF1B6B);

  /// Small, transparent overlay: the real Belople logo, then "Belople" in the
  /// logo's colour, with the poster's @username beneath.
  static Future<ui.Image> _watermarkImage(String username, int videoWidth) async {
    // Smaller than it was: a watermark should sign the video, not compete with
    // it. Roughly two thirds of the previous size.
    final scale = (videoWidth / 720).clamp(0.7, 2.2) * 0.66;
    final nameSize = 30.0 * scale;
    final userSize = 21.0 * scale;
    final pad = 10.0 * scale;
    final gap = 10.0 * scale;

    final logo = await _logoTransparent();
    final name = _gradientPainter('Belople', nameSize, const [_logoOrange, _logoPink]);
    final user = _painter('@$username', userSize, FontWeight.w600);

    // Logo spans both text lines; keep its aspect ratio.
    final logoH = nameSize + userSize * 0.9;
    final logoW = logoH * (logo.width / logo.height);

    final textWidth = math.max(name.width, user.width);
    final width = (pad * 2 + logoW + gap + textWidth).ceil();
    final height = (pad * 2 + name.height + userSize * 0.2 + user.height).ceil();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Logo on the left (before the name), vertically centred.
    final logoY = (height - logoH) / 2;
    canvas.drawImageRect(
      logo,
      Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
      Rect.fromLTWH(pad, logoY, logoW, logoH),
      Paint()..filterQuality = FilterQuality.high,
    );

    final textX = pad + logoW + gap;
    name.paint(canvas, Offset(textX, pad));
    user.paint(canvas, Offset(textX, pad + name.height + userSize * 0.2));

    final picture = recorder.endRecording();
    return picture.toImage(width, height);
  }

  /// The Belople mark (`belople_mark.jpg`) with its black background keyed out
  /// and cropped to the logo's bounds, so it sits cleanly on any frame with no
  /// black box. Cached — the pixel pass runs once per session.
  static ui.Image? _cachedMark;
  static Future<ui.Image> _logoTransparent() async {
    if (_cachedMark != null) return _cachedMark!;
    final raw = await _loadImageAsset('assets/icon/belople_mark.jpg');
    final w = raw.width, h = raw.height;
    final bd = await raw.toByteData(format: ui.ImageByteFormat.rawRgba);
    final px = bd!.buffer.asUint8List();

    var minX = w, minY = h, maxX = 0, maxY = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        final lum = px[i] * 0.30 + px[i + 1] * 0.59 + px[i + 2] * 0.11;
        if (lum < 24) {
          px[i + 3] = 0; // near-black background → transparent
        } else if (lum < 60) {
          px[i + 3] = (((lum - 24) / 36) * 255).round().clamp(0, 255); // feathered edge
        }
        if (px[i + 3] > 20) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }

    final full = await _imageFromPixels(px, w, h);
    if (maxX <= minX || maxY <= minY) {
      _cachedMark = full;
      return full;
    }
    // Crop to the logo's visible bounds.
    final cw = maxX - minX + 1, ch = maxY - minY + 1;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      full,
      Rect.fromLTWH(minX.toDouble(), minY.toDouble(), cw.toDouble(), ch.toDouble()),
      Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()),
      Paint(),
    );
    _cachedMark = await recorder.endRecording().toImage(cw, ch);
    return _cachedMark!;
  }

  static Future<ui.Image> _imageFromPixels(Uint8List pixels, int w, int h) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(pixels, w, h, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  /// A TextPainter whose glyphs are filled with a gradient (for the "Belople"
  /// wordmark in the logo's colours).
  static TextPainter _gradientPainter(String text, double size, List<Color> colors) {
    final measure = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontSize: size, fontWeight: FontWeight.w800)),
      textDirection: TextDirection.ltr,
    )..layout();
    final shader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: colors,
    ).createShader(Rect.fromLTWH(0, 0, measure.width, measure.height));
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w800,
          foreground: Paint()..shader = shader,
          shadows: const [Shadow(color: Colors.black54, blurRadius: 4, offset: Offset(0, 1))],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  /// Copies the bundled outro clip out to a real file FFmpeg can read (once)
  /// and probes it for audio + duration. Cached for the session.
  static _OutroInfo? _cachedOutro;
  static Future<_OutroInfo> _outroInfo() async {
    if (_cachedOutro != null) return _cachedOutro!;
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/belople_outro.mp4');
    // Always rewrite so a new bundled outro replaces any stale copy left from a
    // previous version.
    final data = await rootBundle.load(_outroAsset);
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    final probe = await _probe(file.path);
    return _cachedOutro = _OutroInfo(
      path: file.path,
      hasAudio: probe.hasAudio,
      duration: probe.durationSeconds ?? _outroFallbackSeconds.toDouble(),
    );
  }

  static TextPainter _painter(String text, double size, FontWeight weight,
      {Color color = Colors.white}) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: weight,
          shadows: const [Shadow(color: Colors.black54, blurRadius: 4, offset: Offset(0, 1))],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  static Future<ui.Image> _loadImageAsset(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  static Future<void> _writePng(String path, ui.Image image) async {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('PNG encode failed');
    await File(path).writeAsBytes(bytes.buffer.asUint8List());
  }

  static void _quietDelete(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}

class _Probe {
  const _Probe(this.width, this.height, this.hasAudio, this.durationSeconds);
  final int? width;
  final int? height;
  final bool hasAudio;
  final double? durationSeconds;
}

class _OutroInfo {
  const _OutroInfo({required this.path, required this.hasAudio, required this.duration});
  final String path;
  final bool hasAudio;
  final double duration;
}
