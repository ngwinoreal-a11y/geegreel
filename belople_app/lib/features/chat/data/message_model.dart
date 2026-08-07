import '../../../core/utils/parsing.dart';
import '../../auth/data/user_model.dart';

/// A single message in a thread — `GET /api/messages/:userIdOrUsername` /
/// `POST /api/messages` shape, see src/index.js. NOTE: the backend does
/// NOT return a `senderId` field on thread messages — it returns a
/// precomputed `outgoing` boolean (`m.sender_id === user.id`) instead, so
/// the bubble-alignment check has to use that directly rather than
/// comparing ids client-side (there's no id to compare against here).
class MessageModel {
  const MessageModel({
    required this.id,
    required this.outgoing,
    this.body,
    this.videoId,
    this.imageUrl,
    this.audioUrl,
    this.audioDuration,
    required this.createdAt,
    this.read = false,
    this.deleted = false,
  });

  final String id;
  final bool outgoing;
  final String? body;
  final String? videoId;
  final String? imageUrl;
  final String? audioUrl;
  final double? audioDuration;
  final DateTime createdAt;
  final bool read;
  final bool deleted;

  factory MessageModel.fromJson(Map<String, dynamic> json) => MessageModel(
        id: json['id'].toString(),
        outgoing: json['outgoing'] as bool? ?? false,
        body: json['body'] as String?,
        videoId: json['videoId']?.toString(),
        imageUrl: json['imageUrl'] as String?,
        audioUrl: json['audioUrl'] as String?,
        audioDuration: (json['audioDuration'] as num?)?.toDouble(),
        createdAt: parseTimestamp(json['createdAt']),
        read: json['read'] as bool? ?? false,
        deleted: json['deleted'] as bool? ?? false,
      );
}

/// One row in the inbox — `GET /api/messages`. NOTE: the `with` object here
/// does NOT include the other user's id (see src/index.js's inbox query) —
/// only `GET /api/messages/:who` (the thread fetch) resolves a real id, in
/// its own `with.id`. Anything needing the id (accept/decline a request)
/// has to go through the thread, not this preview.
class ThreadPreview {
  const ThreadPreview({
    required this.user,
    this.lastMessage,
    this.lastMessageAt,
    this.unreadCount = 0,
    this.online = false,
    this.requestStatus = 'accepted',
    this.requestedByMe = false,
  });

  final UserModel user;
  final String? lastMessage;
  final DateTime? lastMessageAt;
  final int unreadCount;
  final bool online;
  final String requestStatus;
  final bool requestedByMe;

  /// A pending request I need to accept/decline (someone I don't follow
  /// back messaged me first) — see design-2.css section G / index.html's
  /// messageRequestsPage().
  bool get isPendingRequestToMe => requestStatus == 'pending' && !requestedByMe;

  factory ThreadPreview.fromJson(Map<String, dynamic> json) {
    final userJson = json['user'] as Map<String, dynamic>? ?? json['with'] as Map<String, dynamic>? ?? const {};
    return ThreadPreview(
      user: UserModel.fromJson(userJson),
      lastMessage: json['lastMessage'] as String? ?? json['body'] as String?,
      lastMessageAt: (json['lastMessageAt'] ?? json['createdAt']) != null
          ? parseTimestamp(json['lastMessageAt'] ?? json['createdAt'])
          : null,
      unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
      online: userJson['online'] as bool? ?? false,
      requestStatus: json['requestStatus'] as String? ?? 'accepted',
      requestedByMe: json['requestedByMe'] as bool? ?? false,
    );
  }
}
