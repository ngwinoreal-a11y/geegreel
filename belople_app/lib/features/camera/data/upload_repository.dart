import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import 'faststart_service.dart';

/// `POST /api/videos` (multipart) — see src/index.js. Uses Dio's
/// `onSendProgress` for the upload bar, matching the web app's raw-XHR
/// upload-progress pattern (index.html uses XMLHttpRequest specifically for
/// this same reason).
class UploadRepository {
  UploadRepository(this._dio);
  final Dio _dio;

  /// Returns the created video's id (for the "posted" popup's share/copy link).
  ///
  /// [thumbnail] is a JPEG of the first frame (see the composer's
  /// _makeThumbnail) — the backend stores it as thumb_key so the profile grid
  /// cell and the feed's pre-playback frame show a poster instead of black.
  /// [width]/[height]/[duration] come from the preview controller.
  Future<String> uploadVideo({
    required File file,
    required String caption,
    String visibility = 'public',
    String? soundId,
    bool soundShareable = false,
    File? thumbnail,
    int? width,
    int? height,
    double? duration,
    void Function(int sent, int total)? onProgress,
  }) async {
    // Rewrite the container so playback can start on the first bytes instead of
    // the last — see FaststartService. Falls back to the original on failure.
    final uploadFile = await FaststartService.prepare(file);
    final formData = FormData.fromMap({
      'caption': caption,
      'visibility': visibility,
      // A video either uses an existing sound OR opts in to become a new
      // shareable sound — never both (mirrors the /api/videos handler).
      if (soundId != null) 'soundId': soundId,
      if (soundId == null && soundShareable) 'soundShareable': '1',
      if (width != null) 'width': '$width',
      if (height != null) 'height': '$height',
      if (duration != null) 'duration': '$duration',
      if (thumbnail != null)
        'thumbnail': await MultipartFile.fromFile(thumbnail.path, filename: 'thumb.jpg'),
      'video': await MultipartFile.fromFile(uploadFile.path, filename: 'upload.mp4'),
    });
    final res = await _dio.post('/videos', data: formData, onSendProgress: onProgress);
    // Clean up the remuxed copy; the user's original take is untouched.
    if (uploadFile.path != file.path) {
      try { await uploadFile.delete(); } catch (_) {}
    }
    final data = res.data as Map<String, dynamic>;
    return (data['video'] as Map<String, dynamic>?)?['id']?.toString() ?? '';
  }

  Future<void> uploadPost({
    File? imageFile,
    required String content,
    void Function(int sent, int total)? onProgress,
  }) async {
    final formData = FormData.fromMap({
      'content': content,
      if (imageFile != null)
        'image': await MultipartFile.fromFile(imageFile.path, filename: 'post.jpg'),
    });
    await _dio.post('/posts', data: formData, onSendProgress: onProgress);
  }
}

final uploadRepositoryProvider = Provider<UploadRepository>((ref) {
  return UploadRepository(ref.watch(dioProvider));
});
