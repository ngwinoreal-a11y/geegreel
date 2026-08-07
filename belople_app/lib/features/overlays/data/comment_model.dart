import '../../../core/utils/parsing.dart';
import '../../auth/data/user_model.dart';

/// Comment shape returned by `GET/POST /api/videos/:id/comments` and the
/// Public-tab equivalent `/api/posts/:id/comments` — nested one level
/// (replies array), each carrying `likes`/`dislikes`/`myReaction` (see
/// `POST /api/comments/:id/react`).
class CommentModel {
  const CommentModel({
    required this.id,
    required this.body,
    required this.user,
    required this.createdAt,
    this.likes = 0,
    this.dislikes = 0,
    this.myReaction,
    this.replies = const [],
  });

  final String id;
  final String body;
  final UserModel user;
  final DateTime createdAt;
  final int likes;
  final int dislikes;
  final String? myReaction;
  final List<CommentModel> replies;

  CommentModel copyWith({int? likes, int? dislikes, String? myReaction}) {
    return CommentModel(
      id: id,
      body: body,
      user: user,
      createdAt: createdAt,
      likes: likes ?? this.likes,
      dislikes: dislikes ?? this.dislikes,
      myReaction: myReaction,
      replies: replies,
    );
  }

  factory CommentModel.fromJson(Map<String, dynamic> json) {
    final userJson = json['user'] as Map<String, dynamic>? ?? const {};
    return CommentModel(
      id: json['id'].toString(),
      body: json['body'] as String? ?? '',
      user: UserModel(
        id: (userJson['id'] ?? '').toString(),
        username: userJson['username'] as String? ?? '',
        displayName: userJson['displayName'] as String? ?? userJson['username'] as String? ?? '',
        avatarUrl: userJson['avatarUrl'] as String?,
      ),
      createdAt: parseTimestamp(json['createdAt']),
      likes: (json['likes'] as num?)?.toInt() ?? 0,
      dislikes: (json['dislikes'] as num?)?.toInt() ?? 0,
      myReaction: json['myReaction'] as String?,
      replies: (json['replies'] as List<dynamic>? ?? [])
          .map((r) => CommentModel.fromJson(r as Map<String, dynamic>))
          .toList(),
    );
  }
}
