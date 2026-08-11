import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Moves an MP4's `moov` atom to the front of the file before upload.
///
/// An MP4 recorded on a phone usually writes `moov` — the index that says where
/// every frame lives — at the END, because its size isn't known until recording
/// stops. A player streaming that file over HTTP can't decode a single frame
/// until it has fetched the index, so it downloads the WHOLE video first. That
/// is what made videos take so long to start: not bandwidth, but layout.
///
/// `-c copy` means remux, not re-encode: no quality loss, no visible wait, it
/// just rewrites the container with the index in front. Videos that went
/// through the sound mixer already got `+faststart` there; this covers the
/// plain-upload path, which is most of them.
class FaststartService {
  /// Returns a faststart copy of [input], or [input] itself if the remux fails.
  /// Never throws: a slow-starting video is a much better outcome than a post
  /// the user can't publish at all.
  static Future<File> prepare(File input) async {
    try {
      final dir = await getTemporaryDirectory();
      final out = '${dir.path}/fs_${DateTime.now().millisecondsSinceEpoch}.mp4';

      final session = await FFmpegKit.executeWithArguments([
        '-y',
        '-i', input.path,
        '-c', 'copy',
        '-movflags', '+faststart',
        out,
      ]);

      final code = await session.getReturnCode();
      final file = File(out);
      if (ReturnCode.isSuccess(code) && await file.exists() && await file.length() > 0) {
        return file;
      }
      // Some recordings can't be stream-copied (odd codec/container). Upload
      // the original rather than failing the post.
      if (await file.exists()) await file.delete();
      debugPrint('faststart skipped: ffmpeg returned $code');
    } catch (e) {
      debugPrint('faststart skipped: $e');
    }
    return input;
  }
}
