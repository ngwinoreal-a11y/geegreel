import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';

/// `POST /api/videos` (multipart) — see src/index.js. Uses Dio's
/// `onSendProgress` for the upload bar, matching the web app's raw-XHR
/// upload-progress pattern (index.html uses XMLHttpRequest specifically for
/// this same reason).
class UploadRepository {
  UploadRepository(this._dio);
  final Dio _dio;

  Future<void> uploadVideo({
    required File file,
    required String caption,
    String visibility = 'public',
    void Function(int sent, int total)? onProgress,
  }) async {
    final formData = FormData.fromMap({
      'caption': caption,
      'visibility': visibility,
      'video': await MultipartFile.fromFile(file.path, filename: 'upload.mp4'),
    });
    await _dio.post('/videos', data: formData, onSendProgress: onProgress);
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
