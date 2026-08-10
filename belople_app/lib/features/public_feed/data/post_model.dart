import '../../../core/utils/parsing.dart';
import '../../feed/data/video_model.dart';

/// Mirrors the Public (photo feed) tab's post shape — `GET /api/posts`, see
/// src/index.js and public/public.js. `imageWidth`/`imageHeight` back the
/// inline `aspect-ratio` design-public.css calls load-bearing (reserves
/// layout space before the image downloads).
class PostModel {
  const PostModel({
    required this.id,
    required this.content,
    this.imageUrl,
    this.imageWidth,
    this.imageHeight,
    required this.user,
    this.likes = 0,
    this.comments = 0,
    this.shares = 0,
    this.liked = false,
    this.following = false,
    required this.createdAt,
  });

  final String id;
  final String content;
  final String? imageUrl;
  final int? imageWidth;
  final int? imageHeight;
  final VideoAuthor user;
  final int likes;
  final int comments;
  final int shares;
  final bool liked;
  final bool following;
  final DateTime createdAt;

  double get aspectRatio {
    if (imageWidth != null && imageHeight != null && imageHeight! > 0) {
      return imageWidth! / imageHeight!;
    }
    return 4 / 5;
  }

  PostModel copyWith({bool? liked, int? likes, int? shares, bool? following}) {
    return PostModel(
      id: id,
      content: content,
      imageUrl: imageUrl,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      user: user,
      likes: likes ?? this.likes,
      comments: comments,
      shares: shares ?? this.shares,
      liked: liked ?? this.liked,
      following: following ?? this.following,
      createdAt: createdAt,
    );
  }

  factory PostModel.fromJson(Map<String, dynamic> json) => PostModel(
        id: json['id'].toString(),
        content: json['content'] as String? ?? '',
        imageUrl: json['mediaUrl'] as String?,
        imageWidth: (json['width'] as num?)?.toInt(),
        imageHeight: (json['height'] as num?)?.toInt(),
        user: VideoAuthor.fromJson(json['user'] as Map<String, dynamic>? ?? const {}),
        likes: (json['counts']?['likes'] as num?)?.toInt() ?? 0,
        comments: (json['counts']?['comments'] as num?)?.toInt() ?? 0,
        shares: (json['counts']?['shares'] as num?)?.toInt() ?? 0,
        liked: json['liked'] as bool? ?? false,
        following: json['following'] as bool? ?? false,
        createdAt: parseTimestamp(json['createdAt']),
      );
}
