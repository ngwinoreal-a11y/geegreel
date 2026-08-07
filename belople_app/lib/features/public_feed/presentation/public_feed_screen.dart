import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/skeleton.dart';
import '../../auth/application/auth_controller.dart';
import '../../feed/data/feed_repository.dart';
import '../../feed/data/video_model.dart';
import '../application/public_feed_controller.dart';
import '../data/post_model.dart';

/// Ports public.js's mountPublic(): an Instagram-like photo feed with one
/// video spliced in after every 3 photo posts (drawn from the For You feed,
/// ads excluded), on top of the photo-post render/like/infinite-scroll path.
class PublicFeedScreen extends ConsumerStatefulWidget {
  const PublicFeedScreen({super.key});

  @override
  ConsumerState<PublicFeedScreen> createState() => _PublicFeedScreenState();
}

/// One video after every N photo posts (matches public.js's postsSinceVideo).
const _videoEvery = 3;

class _PublicFeedScreenState extends ConsumerState<PublicFeedScreen> {
  late final ScrollController _scrollController;

  // Videos to splice in, drawn lazily from the For You feed. Kept in the
  // screen (not the posts controller) so the photo feed's caching stays
  // untouched — mirrors public.js's separate videoPool/videoCursor state.
  final List<VideoModel> _videoPool = [];
  String? _videoCursor;
  bool _videoDone = false;
  bool _videoLoading = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()..addListener(_onScroll);
    _loadVideos();
  }

  Future<void> _loadVideos() async {
    if (_videoLoading || _videoDone) return;
    _videoLoading = true;
    try {
      final page = await ref
          .read(feedRepositoryProvider)
          .fetchFeed(tab: 'foryou', cursor: _videoCursor, limit: 12);
      if (!mounted) return;
      setState(() {
        _videoCursor = page.nextCursor;
        if (page.nextCursor == null) _videoDone = true;
        _videoPool.addAll(page.videos.where((v) => !v.isAd));
      });
    } catch (_) {
      _videoDone = true;
    } finally {
      _videoLoading = false;
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >
        _scrollController.position.maxScrollExtent - 800) {
      ref.read(publicFeedControllerProvider.notifier).loadMore();
    }
  }

  /// Interleaves posts and pooled videos: post, post, post, video, post…
  /// A video slot with no video left (pool not yet refilled) is simply
  /// skipped rather than blocking the feed.
  List<_FeedItem> _interleave(List<PostModel> posts) {
    final items = <_FeedItem>[];
    var videoIdx = 0;
    for (var i = 0; i < posts.length; i++) {
      items.add(_PostItem(posts[i]));
      if ((i + 1) % _videoEvery == 0) {
        if (videoIdx < _videoPool.length) {
          items.add(_VideoItem(_videoPool[videoIdx]));
          videoIdx++;
        } else if (!_videoDone) {
          // Ran dry mid-feed — pull the next page for later frames.
          _loadVideos();
        }
      }
    }
    return items;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(publicFeedControllerProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Public')),
      body: feedAsync.when(
        loading: () => ListView.builder(
          itemCount: 3,
          itemBuilder: (context, i) => const _PostSkeleton(),
        ),
        error: (e, _) => Center(
          child: Text("Couldn't load posts", style: AppTypography.sans(color: AppColors.muted)),
        ),
        data: (state) {
          if (state.posts.isEmpty) {
            return Center(child: Text('No posts yet', style: AppTypography.sans(color: AppColors.muted)));
          }
          final items = _interleave(state.posts);
          return ListView.builder(
            controller: _scrollController,
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              if (item is _VideoItem) {
                return _VideoCard(video: item.video);
              }
              final post = (item as _PostItem).post;
              return _PostCard(
                post: post,
                onLikeTap: () =>
                    ref.read(publicFeedControllerProvider.notifier).toggleLike(post.id),
              );
            },
          );
        },
      ),
    );
  }
}

class _PostCard extends ConsumerWidget {
  const _PostCard({required this.post, required this.onLikeTap});
  final PostModel post;
  final VoidCallback onLikeTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.publicPostPadding, vertical: 10),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => context.push('/profile/${post.user.username}'),
                  child: AppAvatar(
                    size: 32,
                    imageUrl: post.user.avatarUrl != null ? mediaUrl(post.user.avatarUrl!) : null,
                    displayName: post.user.displayName,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    onTap: () => context.push('/profile/${post.user.username}'),
                    child: Text(post.user.displayName,
                        style: AppTypography.sans(fontWeight: FontWeight.w600, fontSize: 14)),
                  ),
                ),
                if (!post.following)
                  Text('Follow', style: AppTypography.sans(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.verified)),
              ],
            ),
          ),
          if (post.imageUrl != null)
            AspectRatio(
              aspectRatio: post.aspectRatio,
              child: Image.network(mediaUrl(post.imageUrl!), fit: BoxFit.contain, width: double.infinity),
            )
          else if (post.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.publicPostPadding),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
                child: Text(post.content, style: AppTypography.sans(fontSize: 14, fontWeight: FontWeight.w700)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.publicPostPadding, 12, AppSpacing.publicPostPadding, 0),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () {
                    if (!ref.read(isLoggedInProvider)) {
                      context.push('/login');
                    } else {
                      onLikeTap();
                    }
                  },
                  child: Row(children: [
                    Icon(post.liked ? Icons.favorite : Icons.favorite_border,
                        color: post.liked ? AppColors.badge : AppColors.text, size: 26),
                    const SizedBox(width: 7),
                    Text('${post.likes}', style: AppTypography.mono(fontSize: 15)),
                  ]),
                ),
                const SizedBox(width: 20),
                Icon(Icons.mode_comment_outlined, color: AppColors.text, size: 24),
                const SizedBox(width: 7),
                Text('${post.comments}', style: AppTypography.mono(fontSize: 15)),
                const SizedBox(width: 20),
                const Icon(Icons.reply_rounded, color: AppColors.text, size: 24),
                const SizedBox(width: 7),
                Text('${post.shares}', style: AppTypography.mono(fontSize: 15)),
              ],
            ),
          ),
          if (post.imageUrl != null && post.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.publicPostPadding, 10, AppSpacing.publicPostPadding, 0),
              child: Text(post.content, style: AppTypography.sans(fontSize: 15)),
            ),
        ],
      ),
    );
  }
}

/// A row in the interleaved public feed: either a photo post or a spliced-in
/// video pulled from the For You feed.
sealed class _FeedItem {
  const _FeedItem();
}

class _PostItem extends _FeedItem {
  const _PostItem(this.post);
  final PostModel post;
}

class _VideoItem extends _FeedItem {
  const _VideoItem(this.video);
  final VideoModel video;
}

/// A spliced video shown as a tappable 9:16 thumbnail with a play badge —
/// tapping opens the full vertical player at /v/:id.
class _VideoCard extends StatelessWidget {
  const _VideoCard({required this.video});
  final VideoModel video;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: GestureDetector(
        onTap: () => context.push('/v/${video.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.publicPostPadding, vertical: 10),
              child: Row(
                children: [
                  AppAvatar(
                    size: 32,
                    imageUrl: video.user.avatarUrl != null ? mediaUrl(video.user.avatarUrl!) : null,
                    displayName: video.user.displayName,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(video.user.displayName,
                        style: AppTypography.sans(fontWeight: FontWeight.w600, fontSize: 14)),
                  ),
                  Icon(Icons.play_circle_fill, color: AppColors.muted, size: 18),
                  const SizedBox(width: 5),
                  Text('Video', style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
                ],
              ),
            ),
            AspectRatio(
              aspectRatio: 9 / 16,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: const BoxDecoration(color: AppColors.raised),
                    child: video.thumbUrl != null
                        ? Image.network(mediaUrl(video.thumbUrl!), fit: BoxFit.cover)
                        : null,
                  ),
                  const Center(
                    child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 56,
                        shadows: [Shadow(color: Colors.black54, blurRadius: 12)]),
                  ),
                ],
              ),
            ),
            if (video.caption.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.publicPostPadding, 10, AppSpacing.publicPostPadding, 0),
                child: Text(video.caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.sans(fontSize: 15)),
              ),
          ],
        ),
      ),
    );
  }
}

class _PostSkeleton extends StatelessWidget {
  const _PostSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        children: [
          const AspectRatio(aspectRatio: 4 / 5, child: Skeleton(borderRadius: 0)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: const [
              Skeleton(width: 80, height: 12),
            ]),
          ),
        ],
      ),
    );
  }
}
