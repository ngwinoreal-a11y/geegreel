import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/cache/local_cache.dart';
import '../../../core/network/api_client.dart';
import '../../feed/data/video_model.dart';
import 'post_model.dart';

class PostsPage {
  const PostsPage({required this.posts, this.ad, this.nextCursor});
  final List<PostModel> posts;

  /// The photo/text ad to weave into this page, or null. Sent beside the posts
  /// rather than inside them so a PostModel is only ever a real post — it
  /// reuses VideoModel, which already knows how to be an ad.
  final VideoModel? ad;

  final String? nextCursor;
}

/// `GET /api/posts`, `POST/DELETE /api/posts/:id/like` — see src/index.js.
class PublicFeedRepository {
  PublicFeedRepository(this._dio);
  final Dio _dio;

  static const _cacheKey = 'public_feed';

  PostsPage? readCachedPosts() {
    final raw = LocalCache.getMap(_cacheKey);
    if (raw == null) return null;
    return _parsePage(raw);
  }

  Future<PostsPage> fetchPosts({String? cursor, int limit = 12}) async {
    final res = await _dio.get('/posts', queryParameters: {
      'limit': limit,
      if (cursor != null) 'cursor': cursor,
    });
    final data = res.data as Map<String, dynamic>;
    if (cursor == null) {
      await LocalCache.putJson(_cacheKey, data);
    }
    return _parsePage(data);
  }

  PostsPage _parsePage(Map<String, dynamic> data) {
    final posts = (data['posts'] as List<dynamic>? ?? [])
        .map((p) => PostModel.fromJson(p as Map<String, dynamic>))
        .toList();
    final rawAd = data['ad'] as Map<String, dynamic>?;
    return PostsPage(
      posts: posts,
      ad: rawAd == null ? null : VideoModel.fromJson(rawAd),
      nextCursor: data['nextCursor'] as String?,
    );
  }

  /// `DELETE /api/posts/:id` — removes the caller's own public post.
  Future<void> deletePost(String postId) => _dio.delete('/posts/$postId');

  /// `POST /api/posts/:id/share` — records a share, returns the new count.
  Future<int> sharePost(String postId) async {
    final res = await _dio.post('/posts/$postId/share');
    final data = res.data as Map<String, dynamic>;
    return (data['count'] as num?)?.toInt() ?? 0;
  }

  Future<(bool liked, int count)> setLiked(String postId, bool liked) async {
    final res = liked
        ? await _dio.post('/posts/$postId/like')
        : await _dio.delete('/posts/$postId/like');
    final data = res.data as Map<String, dynamic>;
    return (data['liked'] as bool? ?? liked, (data['count'] as num?)?.toInt() ?? 0);
  }
}

final publicFeedRepositoryProvider = Provider<PublicFeedRepository>((ref) {
  return PublicFeedRepository(ref.watch(dioProvider));
});
