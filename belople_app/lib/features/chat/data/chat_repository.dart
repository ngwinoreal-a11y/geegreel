import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/cache/local_cache.dart';
import '../../../core/network/api_client.dart';
import '../../auth/data/user_model.dart';
import 'message_model.dart';

class ThreadData {
  const ThreadData({
    required this.withUser,
    required this.messages,
    this.requestStatus,
    this.requestedByMe = false,
    this.blocked = false,
    this.blockedByThem = false,
    this.isTyping = false,
    this.online = false,
  });

  final UserModel withUser;
  final List<MessageModel> messages;
  final String? requestStatus;
  final bool requestedByMe;
  final bool blocked;
  final bool blockedByThem;

  /// The other person has pinged the typing endpoint recently (server-side
  /// freshness window). Surfaces the "typing…" line in the thread.
  final bool isTyping;

  /// The other person was active in the last ~2 minutes (server-computed).
  final bool online;

  bool get isPendingRequestToMe => requestStatus == 'pending' && !requestedByMe;
}

/// Chat is poll-based, not WebSocket — matches the existing backend/web app
/// exactly (see the plan's explicit "no WebSocket" decision). Endpoints:
/// `GET /api/messages` (inbox), `GET /api/messages/:who` (thread),
/// `POST /api/messages` (text), `POST /api/presence/ping`.
class ChatRepository {
  ChatRepository(this._dio);
  final Dio _dio;

  static const _inboxCacheKey = 'chat_inbox';
  static String _threadCacheKey(String who) => 'chat_thread_${who.toLowerCase()}';

  List<ThreadPreview>? readCachedInbox() {
    final raw = LocalCache.getMap(_inboxCacheKey);
    if (raw == null) return null;
    return _parseInbox(raw);
  }

  Future<List<ThreadPreview>> fetchInbox() async {
    final res = await _dio.get('/messages');
    final data = res.data as Map<String, dynamic>;
    await LocalCache.putJson(_inboxCacheKey, data);
    return _parseInbox(data);
  }

  List<ThreadPreview> _parseInbox(Map<String, dynamic> data) {
    return (data['threads'] as List<dynamic>? ?? [])
        .map((t) => ThreadPreview.fromJson(t as Map<String, dynamic>))
        .toList();
  }

  Future<int> unreadCount() async {
    final res = await _dio.get('/messages/unread-count');
    return ((res.data as Map<String, dynamic>)['count'] as num?)?.toInt() ?? 0;
  }

  ThreadData? readCachedThread(String who) {
    final raw = LocalCache.getMap(_threadCacheKey(who));
    if (raw == null) return null;
    return _parseThread(raw);
  }

  Future<ThreadData> fetchThread(String who) async {
    final res = await _dio.get('/messages/$who');
    final data = res.data as Map<String, dynamic>;
    await LocalCache.putJson(_threadCacheKey(who), data);
    return _parseThread(data);
  }

  ThreadData _parseThread(Map<String, dynamic> data) {
    final withJson = data['with'] as Map<String, dynamic>? ?? const {};
    return ThreadData(
      withUser: UserModel.fromJson(withJson),
      messages: (data['messages'] as List<dynamic>? ?? [])
          .map((m) => MessageModel.fromJson(m as Map<String, dynamic>))
          .toList(),
      requestStatus: data['requestStatus'] as String?,
      requestedByMe: data['requestedByMe'] as bool? ?? false,
      blocked: data['blocked'] as bool? ?? false,
      blockedByThem: data['blockedByThem'] as bool? ?? false,
      isTyping: data['isTyping'] as bool? ?? false,
      online: withJson['online'] as bool? ?? false,
    );
  }

  Future<void> sendMessage({
    required String recipientId,
    required String body,
    String? replyToId,
  }) async {
    await _dio.post('/messages', data: {
      'recipientId': recipientId,
      'body': body,
      if (replyToId != null) 'replyToId': replyToId,
    });
  }

  /// `POST /api/messages/:id/delete` with `{scope}`. `scope: "everyone"` is
  /// sender-only and time-limited (server enforces 15 min); anything else
  /// deletes just for this side.
  Future<void> deleteMessage(String messageId, {required String scope}) {
    return _dio.post('/messages/$messageId/delete', data: {'scope': scope});
  }

  /// `POST /api/messages/media` (multipart) — see src/index.js. `kind` is
  /// `image` or `audio`; `duration` (seconds) is read server-side only for
  /// `audio` (src/index.js ~2656: `parseFloat(form.get("duration"))`).
  Future<void> sendMedia({
    required String recipientId,
    required File file,
    required String kind,
    String? body,
    double? duration,
  }) async {
    final formData = FormData.fromMap({
      'recipientId': recipientId,
      'kind': kind,
      'file': await MultipartFile.fromFile(file.path),
      if (body != null) 'body': body,
      if (duration != null) 'duration': duration.toStringAsFixed(2),
    });
    await _dio.post('/messages/media', data: formData);
  }

  Future<void> ping() => _dio.post('/presence/ping');

  /// `POST /api/messages/:who/typing` — fire-and-forget while composing; the
  /// recipient's next thread poll picks up the freshness window.
  Future<void> sendTyping(String who) => _dio.post('/messages/$who/typing');

  /// `POST /api/messages/:messageId/react` with `{emoji}` — toggles: sending
  /// the same emoji again removes it (matches the server's upsert/delete).
  Future<void> reactToMessage({required String messageId, required String emoji}) {
    return _dio.post('/messages/$messageId/react', data: {'emoji': emoji});
  }

  /// `POST /api/messages/:otherId/accept|decline` — `otherId` MUST be the
  /// real user id (from `ThreadData.withUser.id`), not a username; the
  /// backend binds it directly against `conversation_status.user_a/user_b`
  /// with no username resolution at this route.
  Future<void> respondToRequest(String otherUserId, {required bool accept}) {
    return _dio.post('/messages/$otherUserId/${accept ? 'accept' : 'decline'}');
  }
}

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return ChatRepository(ref.watch(dioProvider));
});
