import '../../../core/utils/parsing.dart';

/// `GET /api/notifications` — see src/index.js. Types: like, comment, reply,
/// follow, gift, repost. See design-2.css section B for the actor/videoThumb
/// markup this maps to.
class NotificationModel {
  const NotificationModel({
    required this.id,
    required this.type,
    required this.actorUsername,
    required this.actorDisplayName,
    this.actorAvatarUrl,
    this.videoThumb,
    this.videoId,
    required this.read,
    required this.createdAt,
  });

  final String id;
  final String type;
  final String actorUsername;
  final String actorDisplayName;
  final String? actorAvatarUrl;
  final String? videoThumb;
  final String? videoId;
  final bool read;
  final DateTime createdAt;

  String get message => switch (type) {
        'like' => 'liked your video',
        'comment' => 'commented on your video',
        'reply' => 'replied to your comment',
        'follow' => 'started following you',
        'gift' => 'sent you a gift',
        'repost' => 'reposted your video',
        _ => 'interacted with your content',
      };

  factory NotificationModel.fromJson(Map<String, dynamic> json) {
    final actor = json['actor'] as Map<String, dynamic>? ?? const {};
    return NotificationModel(
      id: json['id'].toString(),
      type: json['type'] as String? ?? '',
      actorUsername: actor['username'] as String? ?? '',
      actorDisplayName: actor['displayName'] as String? ?? actor['username'] as String? ?? '',
      actorAvatarUrl: actor['avatarUrl'] as String?,
      videoThumb: json['videoThumb'] as String?,
      videoId: json['videoId']?.toString(),
      read: json['read'] as bool? ?? false,
      createdAt: parseTimestamp(json['createdAt']),
    );
  }
}
