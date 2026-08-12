import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/cache/local_cache.dart';
import '../../../core/network/api_client.dart';
import 'video_model.dart';

class FeedPage {
  const FeedPage({required this.videos, this.nextCursor});
  final List<VideoModel> videos;
  final String? nextCursor;
}

/// `GET /api/feed?tab=foryou|following&limit=&cursor=` — see src/index.js.
/// "following" requires auth; "foryou" is public (and interleaves ads).
class FeedRepository {
  FeedRepository(this._dio);
  final Dio _dio;

  static String _cacheKey(String tab) => 'feed_$tab';

  /// Synchronous read of the last first-page response for `tab`, for
  /// instant-render-then-refresh (see LocalCache doc comment).
  FeedPage? readCachedFeed(String tab) {
    final raw = LocalCache.getMap(_cacheKey(tab));
    if (raw == null) return null;
    return _parsePage(raw);
  }

  Future<FeedPage> fetchFeed({
    required String tab,
    String? cursor,
    int limit = 15,
  }) async {
    final res = await _dio.get('/feed', queryParameters: {
      'tab': tab,
      'limit': limit,
      if (cursor != null) 'cursor': cursor,
    });
    final data = res.data as Map<String, dynamic>;
    if (cursor == null) {
      await LocalCache.putJson(_cacheKey(tab), data);
    }
    return _parsePage(data);
  }

  FeedPage _parsePage(Map<String, dynamic> data) {
    final videos = (data['videos'] as List<dynamic>? ?? [])
        .map((v) => VideoModel.fromJson(v as Map<String, dynamic>))
        .toList();
    return FeedPage(videos: videos, nextCursor: data['nextCursor'] as String?);
  }

  /// `POST/DELETE /api/videos/:id/like` — see src/index.js. Returns the
  /// server's authoritative {liked, count} so the UI never drifts from
  /// reality after an optimistic update.
  Future<(bool liked, int count)> setLiked(String videoId, bool liked) async {
    final res = liked
        ? await _dio.post('/videos/$videoId/like')
        : await _dio.delete('/videos/$videoId/like');
    final data = res.data as Map<String, dynamic>;
    return (data['liked'] as bool? ?? liked, (data['count'] as num?)?.toInt() ?? 0);
  }

  /// `POST/DELETE /api/users/:id/follow`.
  Future<bool> setFollowing(String userId, bool following) async {
    final res = following
        ? await _dio.post('/users/$userId/follow')
        : await _dio.delete('/users/$userId/follow');
    final data = res.data as Map<String, dynamic>;
    return data['following'] as bool? ?? following;
  }

  /// `POST /api/reports` — `videoId`/`commentId`/`reportedUserId` are all
  /// optional per src/index.js; callers pass whichever one applies.
  Future<void> reportVideo(String videoId, String reason, {String? detail}) {
    return _dio.post('/reports', data: {
      'videoId': videoId,
      'reason': reason,
      if (detail != null) 'detail': detail,
    });
  }

  /// `POST/DELETE /api/users/:id/block`.
  Future<void> setBlocked(String userId, bool blocked) {
    return blocked ? _dio.post('/users/$userId/block') : _dio.delete('/users/$userId/block');
  }

  /// `POST /api/videos/:id/repost` — 409 if already reposted (see
  /// design-4.css's copy rules: "You already reposted this").
  Future<void> repost(String videoId) => _dio.post('/videos/$videoId/repost');

  /// `DELETE /api/videos/:id/repost` — undoes the caller's repost (toggle off).
  Future<void> unrepost(String videoId) => _dio.delete('/videos/$videoId/repost');

  /// `POST/DELETE /api/ads/:id/like` — likes/unlikes an ad, returns the count.
  Future<int> setAdLiked(String adId, bool liked) async {
    final res = liked ? await _dio.post('/ads/$adId/like') : await _dio.delete('/ads/$adId/like');
    return ((res.data as Map<String, dynamic>)['count'] as num?)?.toInt() ?? 0;
  }

  /// `POST /api/ads/:id/click` — records a CTA tap (best-effort).
  Future<void> recordAdClick(String adId) => _dio.post('/ads/$adId/click');


  /// `DELETE /api/videos/:id` — removes the caller's own video.
  Future<void> deleteVideo(String videoId) => _dio.delete('/videos/$videoId');

  /// Changes a video already posted. Only the keys passed are touched, so
  /// editing the audience can't silently clear a category. Deleting used to be
  /// the only option, which meant losing the video's likes, comments and watch
  /// history to fix who could see it.
  Future<VideoModel> editVideo(
    String videoId, {
    String? visibility,
    String? category,
    bool clearCategory = false,
    String? country,
    bool clearCountry = false,
  }) async {
    final res = await _dio.patch('/videos/$videoId', data: {
      if (visibility != null) 'visibility': visibility,
      // `null` is a meaningful value here (clear it), so a separate flag says
      // "send null" rather than "omit".
      if (clearCategory) 'category': null else if (category != null) 'category': category,
      if (clearCountry) 'countries': <String>[] else if (country != null) 'countries': [country],
    });
    return VideoModel.fromJson(
        (res.data as Map<String, dynamic>)['video'] as Map<String, dynamic>);
  }

  /// `POST /api/videos/:id/view` — records a watch for Belo Flow. Sends how
  /// long/how much of the clip was watched so the recommender learns from real
  /// behaviour, not just likes. Best-effort: never throws into the UI.
  Future<void> recordWatch(
    String videoId, {
    required int watchMs,
    required int durationMs,
    bool replayed = false,
    bool skipped = false,
  }) async {
    try {
      await _dio.post('/videos/$videoId/view', data: {
        'watchMs': watchMs,
        'durationMs': durationMs,
        if (replayed) 'replayed': true,
        if (skipped) 'skipped': true,
      });
    } catch (_) {/* signal capture must never break playback */}
  }

  /// `POST /api/videos/:id/not-interested` — a strong negative signal that
  /// suppresses this video and similar content for the viewer.
  Future<void> notInterested(String videoId) async {
    try {
      await _dio.post('/videos/$videoId/not-interested');
    } catch (_) {}
  }

  /// `POST /api/videos/:id/share` — returns a share URL. NOTE: design-5.css
  /// flagged this exact button as missing a handler in the reference web
  /// build too ("the share button was the one icon with no click handler
  /// wired to it") — wiring it here closes that gap for real.
  Future<String> share(String videoId) async {
    final res = await _dio.post('/videos/$videoId/share');
    return (res.data as Map<String, dynamic>)['url'] as String;
  }
}

final feedRepositoryProvider = Provider<FeedRepository>((ref) {
  return FeedRepository(ref.watch(dioProvider));
});
