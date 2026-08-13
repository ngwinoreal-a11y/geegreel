import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail_plus/video_thumbnail_plus.dart';
import '../../../core/badges_provider.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/skeleton.dart';
import '../../../core/widgets/top_toast.dart';
import '../../auth/application/auth_controller.dart';
import '../../feed/data/feed_repository.dart';
import '../../feed/data/video_model.dart';
import '../../public_feed/data/post_model.dart';
import '../../public_feed/data/public_feed_repository.dart';
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
          final grid = _gridSlivers(context, profile, isSelf);
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
          Text(profile.user.displayName, style: AppTypography.pageHeading.copyWith(fontSize: 22)),
          Text('@${profile.user.username}', style: AppTypography.sans(color: AppColors.muted, fontSize: 15)),
          if (profile.user.bio != null && profile.user.bio!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(profile.user.bio!, style: AppTypography.sans(fontSize: 15), textAlign: TextAlign.center),
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
            // No ring. A full-width outline around a quiet, occasional action,
            // sitting between the stats and the grid, drew more of the eye than
            // either of them — the same reason History and Monetization lost
            // theirs on the wallet.
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => context.push('/settings'),
                style: TextButton.styleFrom(foregroundColor: AppColors.accent),
                child: const Text('Edit profile'),
              ),
            )
          else
            Row(
              children: [
                // Follow is the action; Following is a state you've already
                // reached. Both used the same loud amber button, so the screen
                // shouted at you to do a thing you'd already done. Filled for
                // the action, quiet outline once it's done.
                Expanded(
                  child: profile.following || profile.requested
                      ? OutlinedButton(
                          onPressed: () async {
                            if (me == null) { context.push('/login'); return; }
                            try {
                              // Cancels a pending request as well as an
                              // accepted follow — both are the same row.
                              await ref.read(feedRepositoryProvider).setFollowing(profile.user.id, false);
                              ref.invalidate(profileProvider(widget.handle));
                            } catch (_) {}
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.muted,
                            side: const BorderSide(color: AppColors.border),
                          ),
                          // A private account has to approve you first. Saying
                          // "Requested" is the whole point: pressing Follow
                          // used to leave the button reading "Follow", so it
                          // looked like the tap had been swallowed.
                          child: Text(profile.following ? 'Following' : 'Requested'),
                        )
                      : ElevatedButton(
                          onPressed: () async {
                            if (me == null) { context.push('/login'); return; }
                            try {
                              await ref.read(feedRepositoryProvider).setFollowing(profile.user.id, true);
                              ref.invalidate(profileProvider(widget.handle));
                            } catch (_) {}
                          },
                          child: const Text('Follow'),
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

  Widget _gridSlivers(BuildContext context, ProfileData profile, bool isSelf) {
    if (_tab == 2) {
      final posts = profile.posts;
      if (posts.isEmpty) return const _EmptyTab(label: 'No public posts yet');
      return SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 3, crossAxisSpacing: 3, childAspectRatio: 9 / 14),
          delegate: SliverChildBuilderDelegate(
            (context, i) => _PostCell(
              post: posts[i],
              // Open THIS post (pass it so it renders instantly), not the top of
              // the public feed.
              onTap: () => context.push('/p/${posts[i].id}', extra: posts[i]),
              onLongPress: isSelf ? () => _confirmDelete(kind: 'post', id: posts[i].id) : null,
            ),
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
          (context, i) => _VideoCell(
            video: videos[i],
            // Open a swipeable feed of this profile's videos starting here.
            onTap: () => context.push('/profile-videos', extra: {'videos': videos, 'index': i}),
            onLongPress: isSelf ? () => _confirmDelete(kind: 'video', id: videos[i].id) : null,
          ),
          childCount: videos.length,
        ),
      ),
    );
  }

  /// Long-press a cell on your own profile to delete that video or post
  /// (owner-only — the backend enforces it too). Refreshes the grid on success.
  Future<void> _confirmDelete({required String kind, required String id}) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text(
                kind == 'video' ? 'Delete this video?' : 'Delete this post?',
                style: AppTypography.sans(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text("This can't be undone.",
                  style: AppTypography.sans(fontSize: 15, color: AppColors.muted)),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.danger),
              title: Text('Delete', style: AppTypography.sans(color: AppColors.danger, fontWeight: FontWeight.w600)),
              onTap: () => Navigator.of(ctx).pop(true),
            ),
            ListTile(
              title: Center(child: Text('Cancel', style: AppTypography.sans(color: AppColors.muted))),
              onTap: () => Navigator.of(ctx).pop(false),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      if (kind == 'video') {
        await ref.read(feedRepositoryProvider).deleteVideo(id);
      } else {
        await ref.read(publicFeedRepositoryProvider).deletePost(id);
      }
      ref.invalidate(profileProvider(widget.handle));
      if (mounted) showTopToast(context, kind == 'video' ? 'Video deleted' : 'Post deleted');
    } catch (e) {
      // Show the backend's reason (e.g. a sound still in use) instead of a blank failure.
      if (mounted) showTopToast(context, apiErrorMessage(e, "Couldn't delete — try again"));
    }
  }
}

class _VideoCell extends StatelessWidget {
  const _VideoCell({required this.video, required this.onTap, this.onLongPress});
  final VideoModel video;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: const BoxDecoration(color: AppColors.raised),
            child: video.thumbUrl != null
                ? CachedNetworkImage(imageUrl: mediaUrl(video.thumbUrl!), fit: BoxFit.cover)
                // Older videos posted before the app generated thumbnails have
                // no thumbUrl — grab their first frame so the cell isn't black
                // (mirrors the web grid's `<video #t=0.1>` fallback).
                : _FirstFrameThumb(videoUrl: mediaUrl(video.videoUrl)),
          ),
          // Who can see this. Without it the owner had no way to tell which of
          // their own videos aren't public — the grid looked identical whether
          // a clip was visible to everyone or to nobody but them.
          if (video.visibility != 'public')
            Positioned(
              right: 5,
              top: 5,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  video.visibility == 'private' ? Icons.lock_rounded : Icons.group_rounded,
                  color: Colors.white,
                  size: 14,
                ),
              ),
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

/// Generates and shows a video's first frame for grid cells whose video was
/// posted before the app attached a thumbnail. The result is cached per URL
/// (in memory for this session) so scrolling the grid doesn't regenerate it.
class _FirstFrameThumb extends StatefulWidget {
  const _FirstFrameThumb({required this.videoUrl});
  final String videoUrl;

  static final Map<String, String> _cache = {};

  @override
  State<_FirstFrameThumb> createState() => _FirstFrameThumbState();
}

class _FirstFrameThumbState extends State<_FirstFrameThumb> {
  String? _path;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cached = _FirstFrameThumb._cache[widget.videoUrl];
    if (cached != null) {
      setState(() => _path = cached);
      return;
    }
    try {
      final dir = await getTemporaryDirectory();
      final path = await VideoThumbnailPlus.thumbnailFile(
        video: widget.videoUrl,
        thumbnailPath: dir.path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 360,
        quality: 60,
      );
      if (path != null) _FirstFrameThumb._cache[widget.videoUrl] = path;
      if (mounted) setState(() => _path = path);
    } catch (_) {/* leave the black cell as-is */}
  }

  @override
  Widget build(BuildContext context) {
    if (_path == null) return const SizedBox.shrink();
    return Image.file(File(_path!), fit: BoxFit.cover);
  }
}

class _PostCell extends StatelessWidget {
  const _PostCell({required this.post, required this.onTap, this.onLongPress});
  final PostModel post;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: DecoratedBox(
        decoration: const BoxDecoration(color: AppColors.raised),
        child: post.imageUrl != null
            ? CachedNetworkImage(imageUrl: mediaUrl(post.imageUrl!), fit: BoxFit.cover)
            : Padding(
                padding: const EdgeInsets.all(8),
                child: Text(post.content, maxLines: 6, overflow: TextOverflow.ellipsis, style: AppTypography.sans(fontSize: 12)),
              ),
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
                      style: AppTypography.sans(fontSize: 17, fontWeight: FontWeight.w700, color: i == current ? AppColors.text : AppColors.muted),
                      children: [
                        TextSpan(text: labels[i].$1),
                        TextSpan(text: ' ${labels[i].$2}', style: AppTypography.sans(fontSize: 14, color: AppColors.muted)),
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
