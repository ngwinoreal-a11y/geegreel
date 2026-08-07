import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import 'post_comment_model.dart';

/// `GET/POST /api/posts/:id/comments`, `POST/DELETE /api/posts/comments/:id/like`,
/// `POST /api/posts/:id/share` — see src/index.js.
class PostCommentRepository {
  PostCommentRepository(this._dio);
  final Dio _dio;

  Future<List<PostComment>> fetch(String postId) async {
    final res = await _dio.get('/posts/$postId/comments');
    final data = res.data as Map<String, dynamic>;
    return (data['comments'] as List<dynamic>? ?? [])
        .map((c) => PostComment.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  /// Returns the new comment plus the post's updated total comment count.
  Future<(PostComment comment, int count)> post(String postId, String body, {String? parentId}) async {
    final res = await _dio.post('/posts/$postId/comments', data: {
      'body': body,
      if (parentId != null) 'parentId': parentId,
    });
    final data = res.data as Map<String, dynamic>;
    return (
      PostComment.fromJson(data['comment'] as Map<String, dynamic>),
      (data['count'] as num?)?.toInt() ?? 0,
    );
  }

  Future<(bool liked, int count)> setLiked(String commentId, bool liked) async {
    final res = liked
        ? await _dio.post('/posts/comments/$commentId/like')
        : await _dio.delete('/posts/comments/$commentId/like');
    final data = res.data as Map<String, dynamic>;
    return (data['liked'] as bool? ?? liked, (data['count'] as num?)?.toInt() ?? 0);
  }

  /// Records a share (every share counts, not one-per-person). Returns the
  /// post's new share count.
  Future<int> share(String postId) async {
    final res = await _dio.post('/posts/$postId/share');
    return ((res.data as Map<String, dynamic>)['count'] as num?)?.toInt() ?? 0;
  }
}

final postCommentRepositoryProvider = Provider<PostCommentRepository>((ref) {
  return PostCommentRepository(ref.watch(dioProvider));
});
