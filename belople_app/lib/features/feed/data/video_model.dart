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
    this.verified = false,
  });

  final String id;
  final String username;
  final String displayName;
  final String? avatarUrl;

  /// The blue verified tick. Driven ONLY by the account being official/admin
  /// (Belople), never by anything else — the backend sends `role`, and only
  /// 'admin' earns the badge.
  final bool verified;

  factory VideoAuthor.fromJson(Map<String, dynamic> json) => VideoAuthor(
        id: json['id'].toString(),
        username: json['username'] as String? ?? '',
        displayName: json['displayName'] as String? ?? json['username'] as String? ?? '',
        avatarUrl: json['avatarUrl'] as String?,
        verified: json['role'] == 'admin',
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

  VideoCounts copyWith({int? likes, int? comments, int? shares, int? reposts}) => VideoCounts(
        likes: likes ?? this.likes,
        comments: comments ?? this.comments,
        shares: shares ?? this.shares,
        reposts: reposts ?? this.reposts,
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
    this.isRepost = false,
    this.repostOf,
    this.isReposted = false,
    this.isAd = false,
    // Ad-only fields (see design-2.css section F / src/index.js ad shaping)
    this.adKind = 'admin',
    this.sponsorName,
    this.ctaText,
    this.linkUrl,
    this.adId,
    this.adType,
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

  /// True when this row is a repost (has repostOf) rather than an original —
  /// used to split the profile's Videos vs Reposts tabs.
  final bool isRepost;

  /// The original creator, when this row is a repost. `user` is then the
  /// person who reposted it (shown as a small "Reposted by" line).
  final VideoAuthor? repostOf;

  /// True when the SIGNED-IN user has reposted this video — drives the rail's
  /// highlighted repost icon. Populated by the backend's `reposted` flag (once
  /// deployed) and flipped optimistically on tap.
  final bool isReposted;

  final bool isAd;

  /// 'user' = a self-serve ad (renders with the creator + full engagement);
  /// 'admin' = a house ad (minimal — one like, no author/comments).
  final String adKind;
  bool get isUserAd => isAd && adKind == 'user';

  final String? sponsorName;
  final String? ctaText;
  final String? linkUrl;
  final String? adId;

  /// 'image' or 'video' — an image ad is shown as a still, not played.
  final String? adType;

  bool get isImageAd => isAd && (adType == 'image' || adType == 'photo');
  bool get isLinkAd => isAd && adType == 'link';

  VideoModel copyWith({
    VideoCounts? counts,
    bool? liked,
    bool? following,
    bool? isReposted,
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
      isRepost: isRepost,
      repostOf: repostOf,
      isReposted: isReposted ?? this.isReposted,
      isAd: isAd,
      sponsorName: sponsorName,
      ctaText: ctaText,
      linkUrl: linkUrl,
      adId: adId,
      adType: adType,
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
      final owner = json['user'] as Map<String, dynamic>?;
      return VideoModel(
        id: json['id'].toString(),
        caption: json['caption'] as String? ?? '',
        videoUrl: (json['mediaUrl'] ?? json['videoUrl'] ?? '') as String,
        createdAt: DateTime.now(),
        // User ads carry their creator; admin ads have no author.
        user: owner != null
            ? VideoAuthor.fromJson(owner)
            : const VideoAuthor(id: '', username: '', displayName: ''),
        isAd: true,
        adKind: json['adKind'] as String? ?? 'admin',
        adType: json['adType'] as String?,
        sponsorName: json['sponsorName'] as String?,
        ctaText: json['ctaText'] as String?,
        linkUrl: json['linkUrl'] as String?,
        adId: json['id']?.toString(),
        liked: json['liked'] as bool? ?? false,
        following: json['following'] as bool? ?? false,
        counts: VideoCounts(
          likes: (json['likes'] as num?)?.toInt() ?? 0,
          comments: (json['comments'] as num?)?.toInt() ?? 0,
        ),
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
      isRepost: json['repostOf'] != null,
      repostOf: json['repostOf'] != null
          ? VideoAuthor.fromJson(json['repostOf'] as Map<String, dynamic>)
          : null,
      isReposted: json['reposted'] as bool? ?? false,
      createdAt: parseTimestamp(json['createdAt']),
      user: VideoAuthor.fromJson(json['user'] as Map<String, dynamic>? ?? const {}),
      counts: VideoCounts.fromJson(json['counts'] as Map<String, dynamic>?),
      liked: json['liked'] as bool? ?? false,
      following: json['following'] as bool? ?? false,
      giftCoins: (json['giftCoins'] as num?)?.toInt() ?? 0,
    );
  }
}
