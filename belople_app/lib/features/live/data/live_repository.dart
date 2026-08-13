import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';

/// Belople's own Live API. Deliberately says nothing about Mux: the backend
/// hands back an ingest URL and a stream key to broadcast to, and a playback
/// URL to watch — which provider produced them is not this layer's business,
/// and swapping one for another should not reach this file.
///
/// The video side lives in live_broadcaster.dart. Comments, viewers, follows
/// and discovery are all Belople's, so they are all here.

class LiveStart {
  const LiveStart({
    required this.sessionId,
    required this.ingestUrl,
    required this.streamKey,
    required this.maxSeconds,
  });

  final String sessionId;
  final String ingestUrl;
  final String streamKey;

  /// How long this broadcast may run. The app counts down from it and stops
  /// itself; the backend and the provider both hold their own limit underneath,
  /// so a killed app cannot leave an encoder running.
  final int maxSeconds;

  /// Where the camera actually pushes to.
  String get publishUrl => '$ingestUrl/$streamKey';

  factory LiveStart.fromJson(Map<String, dynamic> j) => LiveStart(
        sessionId: j['sessionId'] as String,
        ingestUrl: j['ingestUrl'] as String,
        streamKey: j['streamKey'] as String,
        maxSeconds: (j['maxSeconds'] as num?)?.toInt() ?? 3600,
      );
}

class LiveCreator {
  const LiveCreator({required this.id, required this.username, this.displayName, this.avatarUrl});
  final String id;
  final String username;
  final String? displayName;
  final String? avatarUrl;

  String get name => (displayName?.trim().isNotEmpty ?? false) ? displayName! : username;

  factory LiveCreator.fromJson(Map<String, dynamic> j) => LiveCreator(
        id: j['id'] as String,
        username: j['username'] as String? ?? '',
        displayName: j['displayName'] as String?,
        avatarUrl: j['avatarUrl'] as String?,
      );
}

class LiveSession {
  const LiveSession({
    required this.id,
    required this.status,
    required this.creator,
    this.title,
    this.playbackUrl,
    this.startedAt,
    this.viewerCount = 0,
    this.isOwner = false,
    this.following = false,
  });

  final String id;

  /// starting · live · ending · ended · failed
  final String status;
  final LiveCreator creator;
  final String? title;

  /// The live edge. There is no seeking behind it, by design — this is the
  /// live stream's own playback URL and not the recording's.
  final String? playbackUrl;
  final int? startedAt;
  final int viewerCount;
  final bool isOwner;
  final bool following;

  bool get isLive => status == 'live';

  factory LiveSession.fromJson(Map<String, dynamic> j) => LiveSession(
        id: j['id'] as String,
        status: j['status'] as String? ?? 'ended',
        title: j['title'] as String?,
        playbackUrl: j['playbackUrl'] as String?,
        startedAt: (j['startedAt'] as num?)?.toInt(),
        viewerCount: (j['viewerCount'] as num?)?.toInt() ?? 0,
        isOwner: j['isOwner'] == true,
        following: j['following'] == true,
        creator: LiveCreator.fromJson(
            (j['creator'] as Map?)?.cast<String, dynamic>() ?? const {'id': '', 'username': ''}),
      );
}

/// One line in the rising stream. `kind` is what it is — someone typing,
/// someone arriving, someone reacting — because all three share the same strip
/// on screen and so come back in one query rather than three.
class LiveComment {
  const LiveComment({
    required this.id,
    required this.kind,
    required this.body,
    required this.createdAt,
    required this.user,
  });

  final String id;
  final String kind; // comment · join · like
  final String body;
  final int createdAt;
  final LiveCreator user;

  factory LiveComment.fromJson(Map<String, dynamic> j) => LiveComment(
        id: j['id'] as String,
        kind: j['kind'] as String? ?? 'comment',
        body: j['body'] as String? ?? '',
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        user: LiveCreator.fromJson(
            (j['user'] as Map?)?.cast<String, dynamic>() ?? const {'id': '', 'username': ''}),
      );
}

/// One poll's worth: what was said, how many are watching, and whether it is
/// still on. One request rather than three, because it repeats every few
/// seconds for every viewer.
class LiveTick {
  const LiveTick({
    required this.status,
    required this.viewerCount,
    required this.comments,
    required this.since,
  });

  final String status;
  final int viewerCount;
  final List<LiveComment> comments;
  final int since;

  bool get ended => status != 'live';

  factory LiveTick.fromJson(Map<String, dynamic> j) => LiveTick(
        status: j['status'] as String? ?? 'ended',
        viewerCount: (j['viewerCount'] as num?)?.toInt() ?? 0,
        since: (j['since'] as num?)?.toInt() ?? 0,
        comments: ((j['comments'] as List?) ?? const [])
            .map((e) => LiveComment.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}

class LiveRepository {
  LiveRepository(this._dio);
  final Dio _dio;

  /// Opens a session and returns where to push. Throws with the backend's own
  /// message on refusal — "You already have a live going", or the follower
  /// threshold — because those are things the person needs told, not swallowed.
  Future<LiveStart> start({String? title}) async {
    final res = await _dio.post('/live/start', data: {if (title != null) 'title': title});
    return LiveStart.fromJson((res.data as Map).cast<String, dynamic>());
  }

  Future<void> end(String sessionId) => _dio.post('/live/$sessionId/end');

  Future<LiveSession> session(String id) async {
    final res = await _dio.get('/live/$id');
    return LiveSession.fromJson((res.data as Map).cast<String, dynamic>());
  }

  /// The repeating call. [since] is the timestamp of the last line already
  /// shown; only newer ones come back, and there is no way to ask for older.
  Future<LiveTick> tick(String id, {int since = 0}) async {
    final res = await _dio.get('/live/$id/stream', queryParameters: {'since': since});
    return LiveTick.fromJson((res.data as Map).cast<String, dynamic>());
  }

  Future<void> comment(String id, String body) =>
      _dio.post('/live/$id/comments', data: {'body': body});

  /// Reactions arrive as a number, not one request per tap — the taps come in
  /// bursts and the count is meant to be approximate.
  Future<void> react(String id, int count) =>
      _dio.post('/live/$id/like', data: {'count': count});

  Future<void> join(String id) => _dio.post('/live/$id/join');

  /// One request for a whole combo. Holding the gift button is [count] taps,
  /// and they are charged together — a burst that half-succeeded would leave
  /// someone paying for gifts the room never saw.
  Future<void> gift(String id, String giftKey, int count) =>
      _dio.post('/live/$id/gift', data: {'giftKey': giftKey, 'count': count});

  /// What is on right now. Ended sessions are never in here and cannot be
  /// opened — there is no replay.
  Future<List<LiveSession>> active() async {
    final res = await _dio.get('/live/active');
    final list = ((res.data as Map)['lives'] as List?) ?? const [];
    return list
        .map((e) => LiveSession.fromJson({
              ...(e as Map).cast<String, dynamic>(),
              'status': 'live',
            }))
        .toList();
  }
}

final liveRepositoryProvider = Provider<LiveRepository>((ref) {
  return LiveRepository(ref.watch(dioProvider));
});
