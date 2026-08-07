import '../../../core/utils/parsing.dart';
import '../../feed/data/video_model.dart';

/// A comment on a Public photo/text post — `GET/POST /api/posts/:id/comments`.
class PostComment {
  const PostComment({
    required this.id,
    required this.body,
    required this.user,
    this.likes = 0,
    this.liked = false,
    this.parentId,
    required this.createdAt,
  });

  final String id;
  final String body;
  final VideoAuthor user;
  final int likes;
  final bool liked;
  final String? parentId;
  final DateTime createdAt;

  PostComment copyWith({int? likes, bool? liked}) => PostComment(
        id: id,
        body: body,
        user: user,
        likes: likes ?? this.likes,
        liked: liked ?? this.liked,
        parentId: parentId,
        createdAt: createdAt,
      );

  factory PostComment.fromJson(Map<String, dynamic> json) => PostComment(
        id: json['id'].toString(),
        body: json['body'] as String? ?? '',
        user: VideoAuthor.fromJson(json['user'] as Map<String, dynamic>? ?? const {}),
        likes: (json['likes'] as num?)?.toInt() ?? 0,
        liked: json['liked'] as bool? ?? false,
        parentId: json['parentId']?.toString(),
        createdAt: parseTimestamp(json['createdAt']),
      );
}
