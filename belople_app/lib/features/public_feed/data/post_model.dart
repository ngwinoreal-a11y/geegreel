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

  /// True when the server told us the image's real dimensions. Without them we
  /// must not guess a shape: a wide photo forced into a tall 4:5 box was
  /// letterboxed, leaving big empty bands above and below it.
  bool get hasKnownSize => imageWidth != null && imageHeight != null && imageHeight! > 0;

  /// The post's shape, clamped to what a feed row should occupy. An extremely
  /// tall photo would otherwise take more than a screen to scroll past, and an
  /// extremely wide one would be a sliver.
  double get aspectRatio {
    if (!hasKnownSize) return 4 / 5;
    final raw = imageWidth! / imageHeight!;
    return raw.clamp(0.7, 1.91); // 0.7 ≈ portrait limit, 1.91 ≈ landscape limit
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
