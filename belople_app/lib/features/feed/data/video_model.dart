import '../../../core/utils/parsing.dart';

/// Mirrors `shapeVideo` in src/index.js — the shape every video-returning
/// endpoint (`GET /api/feed`, `GET /api/videos/:id`, profile videos, etc.)
/// sends back.
class VideoAuthor {
  const VideoAuthor({
    required this.id,
    required this.username,
    required this.displayName,
    this.avatarUrl,
  });

  final String id;
  final String username;
  final String displayName;
  final String? avatarUrl;

  factory VideoAuthor.fromJson(Map<String, dynamic> json) => VideoAuthor(
        id: json['id'].toString(),
        username: json['username'] as String? ?? '',
        displayName: json['displayName'] as String? ?? json['username'] as String? ?? '',
        avatarUrl: json['avatarUrl'] as String?,
      );
}

class VideoCounts {
  const VideoCounts({
    this.likes = 0,
    this.comments = 0,
    this.shares = 0,
    this.reposts = 0,
  });

  final int likes;
  final int comments;
  final int shares;
  final int reposts;

  factory VideoCounts.fromJson(Map<String, dynamic>? json) => VideoCounts(
        likes: (json?['likes'] as num?)?.toInt() ?? 0,
        comments: (json?['comments'] as num?)?.toInt() ?? 0,
        shares: (json?['shares'] as num?)?.toInt() ?? 0,
        reposts: (json?['reposts'] as num?)?.toInt() ?? 0,
      );
}

class VideoModel {
  const VideoModel({
    required this.id,
    required this.caption,
    this.song,
    this.soundId,
    required this.videoUrl,
    this.thumbUrl,
    this.width,
    this.height,
    this.duration,
    this.views = 0,
    required this.createdAt,
    required this.user,
    this.counts = const VideoCounts(),
    this.liked = false,
    this.following = false,
    this.giftCoins = 0,
    this.isAd = false,
    // Ad-only fields (see design-2.css section F / src/index.js ad shaping)
    this.sponsorName,
    this.ctaText,
    this.linkUrl,
    this.adId,
  });

  final String id;
  final String caption;
  final String? song;
  final String? soundId;
  final String videoUrl;
  final String? thumbUrl;
  final int? width;
  final int? height;
  final double? duration;
  final int views;
  final DateTime createdAt;
  final VideoAuthor user;
  final VideoCounts counts;
  final bool liked;
  final bool following;
  final int giftCoins;

  final bool isAd;
  final String? sponsorName;
  final String? ctaText;
  final String? linkUrl;
  final String? adId;

  VideoModel copyWith({
    VideoCounts? counts,
    bool? liked,
    bool? following,
  }) {
    return VideoModel(
      id: id,
      caption: caption,
      song: song,
      soundId: soundId,
      videoUrl: videoUrl,
      thumbUrl: thumbUrl,
      width: width,
      height: height,
      duration: duration,
      views: views,
      createdAt: createdAt,
      user: user,
      counts: counts ?? this.counts,
      liked: liked ?? this.liked,
      following: following ?? this.following,
      giftCoins: giftCoins,
      isAd: isAd,
      sponsorName: sponsorName,
      ctaText: ctaText,
      linkUrl: linkUrl,
      adId: adId,
    );
  }

  /// Video keeps its own aspect ratio (design.css `.slide video`): 9:16
  /// fills edge to edge, other ratios letterbox. Falls back to 9:16 when the
  /// backend hasn't recorded dimensions.
  double get aspectRatio {
    if (width != null && height != null && height! > 0) {
      return width! / height!;
    }
    return 9 / 16;
  }

  factory VideoModel.fromJson(Map<String, dynamic> json) {
    if (json['isAd'] == true) {
      return VideoModel(
        id: json['id'].toString(),
        caption: json['caption'] as String? ?? '',
        videoUrl: (json['mediaUrl'] ?? json['videoUrl'] ?? '') as String,
        createdAt: DateTime.now(),
        user: const VideoAuthor(id: '', username: '', displayName: ''),
        isAd: true,
        sponsorName: json['sponsorName'] as String?,
        ctaText: json['ctaText'] as String?,
        linkUrl: json['linkUrl'] as String?,
        adId: json['id']?.toString(),
      );
    }
    return VideoModel(
      id: json['id'].toString(),
      caption: json['caption'] as String? ?? '',
      song: json['song'] as String?,
      soundId: json['soundId']?.toString(),
      videoUrl: json['videoUrl'] as String? ?? '',
      thumbUrl: json['thumbUrl'] as String?,
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      duration: (json['duration'] as num?)?.toDouble(),
      views: (json['views'] as num?)?.toInt() ?? 0,
      createdAt: parseTimestamp(json['createdAt']),
      user: VideoAuthor.fromJson(json['user'] as Map<String, dynamic>? ?? const {}),
      counts: VideoCounts.fromJson(json['counts'] as Map<String, dynamic>?),
      liked: json['liked'] as bool? ?? false,
      following: json['following'] as bool? ?? false,
      giftCoins: (json['giftCoins'] as num?)?.toInt() ?? 0,
    );
  }
}
