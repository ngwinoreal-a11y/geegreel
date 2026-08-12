import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/skeleton.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/data/user_model.dart';
import '../data/friends_repository.dart';

enum _FriendsTab { following, followers, friends, suggested }

/// Ports index.html's friendsPage(): reached from the round FAB while on
/// the Messages tab (bottom-nav pill morphs its FAB to "add friend" there
/// — see BottomNavPill's doc comment) — this screen itself was previously
/// missing entirely even though the nav already knew to point at it.
class FriendsScreen extends ConsumerStatefulWidget {
  const FriendsScreen({super.key});

  @override
  ConsumerState<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends ConsumerState<FriendsScreen> {
  _FriendsTab _tab = _FriendsTab.following;
  List<UserModel>? _users;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final me = ref.read(authControllerProvider).valueOrNull?.username;
    if (me == null) {
      setState(() { _loading = false; _error = 'Log in to see friends'; });
      return;
    }
    try {
      final repo = ref.read(friendsRepositoryProvider);
      final users = switch (_tab) {
        _FriendsTab.following => await repo.fetchList(me, 'following'),
        _FriendsTab.followers => await repo.fetchList(me, 'followers'),
        _FriendsTab.friends => await repo.fetchMutuals(me),
        _FriendsTab.suggested => await repo.fetchSuggested(),
      };
      if (mounted) setState(() { _users = users; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = "Couldn't load this list"; _loading = false; });
    }
  }

  void _selectTab(_FriendsTab tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    _load();
  }

  Future<void> _toggleFollow(int index) async {
    final users = _users;
    if (users == null) return;
    final user = users[index];
    final next = !user.following;
    setState(() {
      _users = [
        for (var i = 0; i < users.length; i++)
          if (i == index) _withFollowing(users[i], next) else users[i],
      ];
    });
    try {
      final result = await ref.read(friendsRepositoryProvider).setFollowing(user.id, next);
      if (!mounted) return;
      final latest = _users;
      if (latest == null) return;
      setState(() {
        _users = [
          for (var i = 0; i < latest.length; i++)
            if (latest[i].id == user.id) _withFollowing(latest[i], result) else latest[i],
        ];
      });
    } catch (_) {
      if (!mounted) return;
      final latest = _users;
      if (latest == null) return;
      setState(() {
        _users = [
          for (var i = 0; i < latest.length; i++)
            if (latest[i].id == user.id) user else latest[i],
        ];
      });
    }
  }

  UserModel _withFollowing(UserModel u, bool following) => UserModel(
        id: u.id,
        username: u.username,
        displayName: u.displayName,
        bio: u.bio,
        avatarUrl: u.avatarUrl,
        followersCount: u.followersCount,
        followingCount: u.followingCount,
        likesCount: u.likesCount,
        following: following,
      );

  void _dismiss(int index) {
    final users = _users;
    if (users == null) return;
    setState(() => _users = [for (var i = 0; i < users.length; i++) if (i != index) users[i]]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Friends')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _TabChip(label: 'Following', selected: _tab == _FriendsTab.following, onTap: () => _selectTab(_FriendsTab.following)),
                  const SizedBox(width: 8),
                  _TabChip(label: 'Followers', selected: _tab == _FriendsTab.followers, onTap: () => _selectTab(_FriendsTab.followers)),
                  const SizedBox(width: 8),
                  // "Friends" (mutuals) removed — Following and Followers
                  // already answer the question it was asking, and with three
                  // chips the row no longer needs to scroll. The tab value and
                  // its mutuals fetch are left in place so putting it back is
                  // a one-line change.
                  const SizedBox.shrink(),
                  _TabChip(label: 'Suggested', selected: _tab == _FriendsTab.suggested, onTap: () => _selectTab(_FriendsTab.suggested)),
                ],
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? ListView.builder(
                    itemCount: 6,
                    itemBuilder: (context, i) => const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(children: [
                        Skeleton.avatar(size: 44),
                        SizedBox(width: 12),
                        Expanded(child: Skeleton(height: 12)),
                      ]),
                    ),
                  )
                : _error != null
                    ? Center(child: Text(_error!, style: AppTypography.sans(color: AppColors.muted)))
                    : (_users?.isEmpty ?? true)
                        ? Center(
                            child: Text(_emptyLabel(), style: AppTypography.sans(color: AppColors.muted)),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: _users!.length,
                            itemBuilder: (context, i) => _FriendRow(
                              user: _users![i],
                              subtitle: _tab == _FriendsTab.suggested ? 'Suggested for you' : null,
                              followLabel: _tab == _FriendsTab.followers ? 'Follow back' : 'Follow',
                              dismissible: _tab == _FriendsTab.suggested,
                              onFollowTap: () => _toggleFollow(i),
                              onDismiss: _tab == _FriendsTab.suggested ? () => _dismiss(i) : null,
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  String _emptyLabel() => switch (_tab) {
        _FriendsTab.following => 'Not following anyone yet.',
        _FriendsTab.followers => 'No followers yet.',
        _FriendsTab.friends => 'No mutual friends yet.',
        _FriendsTab.suggested => 'No suggestions right now.',
      };
}

class _TabChip extends StatelessWidget {
  const _TabChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? AppColors.text : AppColors.surface,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Text(
          label,
          style: AppTypography.sans(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: selected ? AppColors.bg : AppColors.text,
          ),
        ),
      ),
    );
  }
}

class _FriendRow extends StatelessWidget {
  const _FriendRow({
    required this.user,
    this.subtitle,
    required this.followLabel,
    required this.dismissible,
    required this.onFollowTap,
    this.onDismiss,
  });

  final UserModel user;
  final String? subtitle;
  final String followLabel;
  final bool dismissible;
  final VoidCallback onFollowTap;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: () => context.push('/profile/${user.username}'),
      leading: AppAvatar(
        size: 44,
        imageUrl: user.avatarUrl != null ? mediaUrl(user.avatarUrl!) : null,
        displayName: user.displayName,
      ),
      title: Text(user.displayName,
          style: AppTypography.sans(fontSize: 17, fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle ?? '@${user.username}',
          style: AppTypography.sans(color: AppColors.muted, fontSize: 14)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: onFollowTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: BoxDecoration(
                // Already-following reads as brand amber instead of another
                // grey pill — it's the state worth seeing at a glance down a
                // long list, and grey-on-dark said nothing.
                color: user.following ? AppColors.accentSoft : AppColors.text,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                user.following ? 'Following' : followLabel,
                style: AppTypography.sans(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: user.following ? AppColors.accent : AppColors.bg,
                ),
              ),
            ),
          ),
          if (dismissible)
            IconButton(
              icon: const Icon(Icons.close, color: AppColors.muted, size: 18),
              onPressed: onDismiss,
            ),
        ],
      ),
    );
  }
}
