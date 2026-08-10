/// Mirrors `privateUser`/`publicUser` shapes in src/index.js.
class UserModel {
  const UserModel({
    required this.id,
    required this.username,
    required this.displayName,
    this.bio,
    this.avatarUrl,
    this.email,
    this.role = 'user',
    this.monetized = false,
    this.coins = 0,
    this.giftBalanceCents = 0,
    this.isPrivate = false,
    this.allowMessages = 'everyone',
    this.allowComments = 'everyone',
    this.notifyLikes = true,
    this.notifyComments = true,
    this.notifyFollows = true,
    this.followersCount = 0,
    this.followingCount = 0,
    this.likesCount = 0,
    this.following = false,
  });

  final String id;
  final String username;
  final String displayName;
  final String? bio;
  final String? avatarUrl;
  final String? email;
  final String role;
  final bool monetized;
  final int coins;
  final int giftBalanceCents;
  final bool isPrivate;
  final String allowMessages;
  final String allowComments;
  final bool notifyLikes;
  final bool notifyComments;
  final bool notifyFollows;
  final int followersCount;
  final int followingCount;
  final int likesCount;
  /// Whether the current session user follows this one — only populated by
  /// the followers/following/suggested list endpoints (src/index.js's
  /// `followedSet`), absent (defaults false) elsewhere.
  final bool following;

  bool get isStaff => role == 'admin' || role == 'moderator';

  factory UserModel.fromJson(Map<String, dynamic> json) => UserModel(
        id: json['id'].toString(),
        username: json['username'] as String? ?? '',
        displayName: json['displayName'] as String? ?? json['username'] as String? ?? '',
        bio: json['bio'] as String?,
        avatarUrl: json['avatarUrl'] as String?,
        email: json['email'] as String?,
        role: json['role'] as String? ?? 'user',
        monetized: json['monetized'] as bool? ?? false,
        coins: (json['coins'] as num?)?.toInt() ?? 0,
        giftBalanceCents: (json['giftBalanceCents'] as num?)?.toInt() ?? 0,
        isPrivate: json['isPrivate'] as bool? ?? false,
        allowMessages: json['allowMessages'] as String? ?? 'everyone',
        allowComments: json['allowComments'] as String? ?? 'everyone',
        notifyLikes: json['notifyLikes'] as bool? ?? true,
        notifyComments: json['notifyComments'] as bool? ?? true,
        notifyFollows: json['notifyFollows'] as bool? ?? true,
        following: json['following'] as bool? ?? false,
      );

  /// Serialised for the offline auth cache (see AuthController) — keeps the
  /// same keys fromJson reads so a cached user round-trips cleanly.
  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'displayName': displayName,
        'bio': bio,
        'avatarUrl': avatarUrl,
        'email': email,
        'role': role,
        'monetized': monetized,
        'coins': coins,
        'giftBalanceCents': giftBalanceCents,
        'isPrivate': isPrivate,
        'allowMessages': allowMessages,
        'allowComments': allowComments,
        'notifyLikes': notifyLikes,
        'notifyComments': notifyComments,
        'notifyFollows': notifyFollows,
        'following': following,
      };

  /// `GET /api/users/:handle` returns stats separately from the user object
  /// — merge them in with this rather than fromJson so the two response
  /// shapes (privateUser vs. profile) don't have to be reconciled in one
  /// parser.
  UserModel withStats(Map<String, dynamic>? stats) {
    if (stats == null) return this;
    return UserModel(
      id: id,
      username: username,
      displayName: displayName,
      bio: bio,
      avatarUrl: avatarUrl,
      email: email,
      role: role,
      monetized: monetized,
      coins: coins,
      giftBalanceCents: giftBalanceCents,
      isPrivate: isPrivate,
      allowMessages: allowMessages,
      allowComments: allowComments,
      notifyLikes: notifyLikes,
      notifyComments: notifyComments,
      notifyFollows: notifyFollows,
      followersCount: (stats['followers'] as num?)?.toInt() ?? followersCount,
      followingCount: (stats['following'] as num?)?.toInt() ?? followingCount,
      likesCount: (stats['likes'] as num?)?.toInt() ?? likesCount,
      following: following,
    );
  }
}
