import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import 'comment_model.dart';

/// `GET/POST /api/videos/:id/comments`, `POST /api/comments/:id/react`,
/// `DELETE /api/comments/:id` — see src/index.js.
class CommentRepository {
  CommentRepository(this._dio);
  final Dio _dio;

  Future<(List<CommentModel> comments, int total)> fetchComments(String videoId) async {
    final res = await _dio.get('/videos/$videoId/comments');
    final data = res.data as Map<String, dynamic>;
    final comments = (data['comments'] as List<dynamic>? ?? [])
        .map((c) => CommentModel.fromJson(c as Map<String, dynamic>))
        .toList();
    return (comments, (data['total'] as num?)?.toInt() ?? comments.length);
  }

  Future<(CommentModel comment, int count)> postComment(
    String videoId,
    String body, {
    String? parentId,
  }) async {
    final res = await _dio.post('/videos/$videoId/comments', data: {
      'body': body,
      if (parentId != null) 'parentId': parentId,
    });
    final data = res.data as Map<String, dynamic>;
    return (
      CommentModel.fromJson(data['comment'] as Map<String, dynamic>),
      (data['count'] as num?)?.toInt() ?? 0,
    );
  }

  /// `kind` must be "like" or "dislike" — the server toggles it off if you
  /// send the same kind that's already set (see src/index.js), there's no
  /// separate "remove" value.
  Future<(int likes, int dislikes, String? myReaction)> react(String commentId, String kind) async {
    final res = await _dio.post('/comments/$commentId/react', data: {'kind': kind});
    final data = res.data as Map<String, dynamic>;
    return (
      (data['likes'] as num?)?.toInt() ?? 0,
      (data['dislikes'] as num?)?.toInt() ?? 0,
      data['myReaction'] as String?,
    );
  }
}

final commentRepositoryProvider = Provider<CommentRepository>((ref) {
  return CommentRepository(ref.watch(dioProvider));
});
