import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:path_provider/path_provider.dart';

/// Mixes a chosen sound INTO a recorded video — the real fix for "use sound
/// doesn't come into the video". The picture is stream-copied (no re-encode,
/// so it's fast — only the audio is rebuilt): the original mic track at
/// [micVolume] is mixed with the sound at [soundVolume], clamped to the
/// video's length. Returns the mixed file's path, or [videoPath] unchanged on
/// any failure so publishing still works.
class AudioMixService {
  static Future<String> mixSound({
    required String videoPath,
    required String soundPath,
    required double micVolume,
    required double soundVolume,
  }) async {
    try {
      final dir = await getTemporaryDirectory();
      final out = '${dir.path}/belople_mixed_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final hasMic = await _hasAudio(videoPath);

      final String filter;
      if (hasMic) {
        // normalize=0 is the whole point: amix normalizes by DEFAULT, dividing
        // every input by the number of inputs and re-weighting as tracks come
        // and go. That threw away the two levels the poster had just set — the
        // mic ended up buried under a mastered-loud library track no matter
        // where the sliders were, which is exactly the "the original can't be
        // heard" complaint. With normalize off, volume= is taken literally.
        filter =
            '[0:a]volume=$micVolume[a0];[1:a]volume=$soundVolume,apad,asetpts=PTS-STARTPTS[a1];'
            '[a0][a1]amix=inputs=2:duration=first:dropout_transition=0:normalize=0,'
            'aresample=44100[aout]';
      } else {
        // No mic track — the chosen sound simply becomes the audio.
        filter = '[1:a]volume=$soundVolume,aresample=44100[aout]';
      }

      final args = [
        '-y', '-i', videoPath, '-i', soundPath,
        '-filter_complex', filter,
        '-map', '0:v', '-map', '[aout]',
        '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k',
        '-shortest', '-movflags', '+faststart', out,
      ];

      final completer = Completer<bool>();
      await FFmpegKit.executeWithArgumentsAsync(args, (session) async {
        final rc = await session.getReturnCode();
        if (!completer.isCompleted) completer.complete(ReturnCode.isSuccess(rc));
      });
      final ok = await completer.future.timeout(const Duration(seconds: 120), onTimeout: () {
        FFmpegKit.cancel();
        return false;
      });
      return (ok && File(out).existsSync()) ? out : videoPath;
    } catch (_) {
      return videoPath;
    }
  }

  /// Does this file carry an audio track at all? The composer asks before
  /// showing a "Your audio" slider — a clip recorded with no sound has nothing
  /// for that slider to raise, and a control that can't do anything is worse
  /// than no control.
  static Future<bool> hasAudio(String path) => _hasAudio(path);

  static Future<bool> _hasAudio(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info == null) return true;
      return info.getStreams().any((s) => s.getType() == 'audio');
    } catch (_) {
      return true;
    }
  }
}
