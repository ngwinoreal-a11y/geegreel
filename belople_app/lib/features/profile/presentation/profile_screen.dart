import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/badges_provider.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/skeleton.dart';
import '../../auth/application/auth_controller.dart';
import '../../feed/data/feed_repository.dart';
import '../../feed/data/video_model.dart';
import '../../public_feed/data/post_model.dart';
import '../data/profile_repository.dart';

/// Ports index.html's profilePage(): avatar/bio/stats, Edit profile (self) or
/// Follow + Message (other), and the Videos / Reposts / Public tabs with a
/// thumbnail grid (play + view count on each cell).
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key, required this.handle});
  final String handle;

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  int _tab = 0; // 0 Videos, 1 Reposts, 2 Public

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(profileProvider(widget.handle));
    final me = ref.watch(authControllerProvider).valueOrNull;
    final isSelf = me != null && me.username.toLowerCase() == widget.handle.toLowerCase();

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text(profileAsync.valueOrNull?.user.displayName ?? '@${widget.handle}'),
        actions: isSelf
            ? [
                IconButton(
                  icon: Badge(
                    label: Text('${ref.watch(unreadNotificationsProvider).valueOrNull ?? 0}'),
                    isLabelVisible: (ref.watch(unreadNotificationsProvider).valueOrNull ?? 0) > 0,
                    child: const Icon(Icons.notifications_outlined),
                  ),
                  onPressed: () => context.push('/notifications'),
                ),
                IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => context.push('/settings')),
                IconButton(icon: const Icon(Icons.account_balance_wallet_outlined), onPressed: () => context.push('/wallet')),
              ]
            : null,
      ),
      body: profileAsync.when(
        loading: () => const _ProfileSkeleton(),
        error: (err, _) => Center(child: Text("Couldn't load this profile", style: AppTypography.sans(color: AppColors.muted))),
        data: (profile) {
          final grid = _gridSlivers(context, profile);
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _header(context, profile, me, isSelf)),
              SliverPersistentHeader(pinned: true, delegate: _TabBarDelegate(profile: profile, current: _tab, onTap: (i) => setState(() => _tab = i))),
              if (profile.locked && !isSelf)
                const SliverToBoxAdapter(
                  child: Padding(padding: EdgeInsets.all(40), child: Center(child: Text('This account is private', style: TextStyle(color: AppColors.muted)))),
                )
              else
                grid,
            ],
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, ProfileData profile, dynamic me, bool isSelf) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.pageHorizontal, 20, AppSpacing.pageHorizontal, 0),
      child: Column(
        children: [
          AppAvatar(
            size: 88,
            imageUrl: profile.user.avatarUrl != null ? mediaUrl(profile.user.avatarUrl!) : null,
            displayName: profile.user.displayName,
          ),
          const SizedBox(height: 10),
          Text(profile.user.displayName, style: AppTypography.pageHeading.copyWith(fontSize: 18)),
          Text('@${profile.user.username}', style: AppTypography.sans(color: AppColors.muted, fontSize: 13)),
          if (profile.user.bio != null && profile.user.bio!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(profile.user.bio!, style: AppTypography.sans(fontSize: 14), textAlign: TextAlign.center),
          ],
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              GestureDetector(onTap: () => context.push('/profile/${widget.handle}/following'), child: _Stat(label: 'Following', value: profile.user.followingCount)),
              GestureDetector(onTap: () => context.push('/profile/${widget.handle}/followers'), child: _Stat(label: 'Followers', value: profile.user.followersCount)),
              _Stat(label: 'Likes', value: profile.user.likesCount),
            ],
          ),
          const SizedBox(height: 16),
          if (isSelf)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(onPressed: () => context.push('/settings'), child: const Text('Edit profile')),
            )
          else
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      if (me == null) { context.push('/login'); return; }
                      try {
                        await ref.read(feedRepositoryProvider).setFollowing(profile.user.id, !profile.following);
                        ref.invalidate(profileProvider(widget.handle));
                      } catch (_) {}
                    },
                    child: Text(profile.following ? 'Following' : 'Follow'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => me == null ? context.push('/login') : context.push('/chat/${profile.user.username}'),
                    child: const Text('Message'),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _gridSlivers(BuildContext context, ProfileData profile) {
    if (_tab == 2) {
      final posts = profile.posts;
      if (posts.isEmpty) return const _EmptyTab(label: 'No public posts yet');
      return SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 3, crossAxisSpacing: 3, childAspectRatio: 9 / 14),
          delegate: SliverChildBuilderDelegate(
            (context, i) => _PostCell(post: posts[i]),
            childCount: posts.length,
          ),
        ),
      );
    }
    final videos = _tab == 0 ? profile.originals : profile.reposts;
    if (videos.isEmpty) return _EmptyTab(label: _tab == 0 ? 'No videos yet' : 'No reposts yet');
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 3, crossAxisSpacing: 3, childAspectRatio: 9 / 14),
        delegate: SliverChildBuilderDelegate(
          (context, i) => _VideoCell(video: videos[i]),
          childCount: videos.length,
        ),
      ),
    );
  }
}

class _VideoCell extends StatelessWidget {
  const _VideoCell({required this.video});
  final VideoModel video;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push('/v/${video.id}'),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: const BoxDecoration(color: AppColors.raised),
            child: video.thumbUrl != null
                ? CachedNetworkImage(imageUrl: mediaUrl(video.thumbUrl!), fit: BoxFit.cover)
                : null,
          ),
          Positioned(
            left: 6,
            bottom: 6,
            child: Row(
              children: [
                const Icon(Icons.play_arrow, color: Colors.white, size: 16, shadows: [Shadow(color: Colors.black87, blurRadius: 4)]),
                const SizedBox(width: 3),
                Text(_fmt(video.views),
                    style: AppTypography.sans(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)
                        .copyWith(shadows: const [Shadow(color: Colors.black87, blurRadius: 4)])),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}

class _PostCell extends StatelessWidget {
  const _PostCell({required this.post});
  final PostModel post;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: AppColors.raised),
      child: post.imageUrl != null
          ? CachedNetworkImage(imageUrl: mediaUrl(post.imageUrl!), fit: BoxFit.cover)
          : Padding(
              padding: const EdgeInsets.all(8),
              child: Text(post.content, maxLines: 6, overflow: TextOverflow.ellipsis, style: AppTypography.sans(fontSize: 12)),
            ),
    );
  }
}

class _EmptyTab extends StatelessWidget {
  const _EmptyTab({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(padding: const EdgeInsets.all(40), child: Center(child: Text(label, style: AppTypography.sans(color: AppColors.muted)))),
    );
  }
}

/// Pinned tab strip: Videos N / Reposts N / Public N.
class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  _TabBarDelegate({required this.profile, required this.current, required this.onTap});
  final ProfileData profile;
  final int current;
  final ValueChanged<int> onTap;

  @override
  double get minExtent => 46;
  @override
  double get maxExtent => 46;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final labels = [
      ('Videos', profile.originals.length),
      ('Reposts', profile.reposts.length),
      ('Public', profile.posts.length),
    ];
    return Container(
      color: AppColors.bg,
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onTap(i),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(width: 2, color: i == current ? AppColors.text : Colors.transparent)),
                  ),
                  alignment: Alignment.center,
                  child: RichText(
                    text: TextSpan(
                      style: AppTypography.sans(fontSize: 14, fontWeight: FontWeight.w700, color: i == current ? AppColors.text : AppColors.muted),
                      children: [
                        TextSpan(text: labels[i].$1),
                        TextSpan(text: ' ${labels[i].$2}', style: AppTypography.sans(fontSize: 13, color: AppColors.muted)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) =>
      oldDelegate.current != current || oldDelegate.profile != profile;
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('$value', style: AppTypography.statNumber),
        Text(label, style: AppTypography.statLabel),
      ],
    );
  }
}

class _ProfileSkeleton extends StatelessWidget {
  const _ProfileSkeleton();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(AppSpacing.pageHorizontal),
      child: Column(children: [Skeleton.avatar(size: 88), SizedBox(height: 16), Skeleton(width: 140, height: 14)]),
    );
  }
}
