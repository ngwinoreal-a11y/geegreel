import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/brand_wordmark.dart';
import '../../../core/widgets/linkified_text.dart';
import '../../../core/widgets/skeleton.dart';
import '../../auth/application/auth_controller.dart';
import '../../feed/data/feed_repository.dart';
import '../../feed/data/video_model.dart';
import '../application/public_feed_controller.dart';
import '../data/post_comment_repository.dart';
import '../data/post_model.dart';
import 'post_comments_sheet.dart';

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
      appBar: AppBar(
        centerTitle: true,
        title: const BrandWordmark(),
      ),
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
                    size: 34,
                    ring: true,
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
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () async {
                      if (!ref.read(isLoggedInProvider)) {
                        context.push('/login');
                        return;
                      }
                      try {
                        await ref.read(feedRepositoryProvider).setFollowing(post.user.id, true);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Following @${post.user.username}')));
                        }
                      } catch (_) {}
                    },
                    child: Text('Follow',
                        style: AppTypography.sans(
                            fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.verified)),
                  ),
              ],
            ),
          ),
          if (post.imageUrl != null)
            AspectRatio(
              aspectRatio: post.aspectRatio,
              child: CachedNetworkImage(imageUrl: mediaUrl(post.imageUrl!), fit: BoxFit.contain, width: double.infinity),
            )
          else if (post.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.publicPostPadding),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
                child: LinkifiedText(text: post.content, style: AppTypography.sans(fontSize: 14, fontWeight: FontWeight.w700)),
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
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => showPostCommentsSheet(context, postId: post.id),
                  child: Row(children: [
                    const Icon(Icons.mode_comment, color: AppColors.text, size: 24),
                    const SizedBox(width: 7),
                    Text('${post.comments}', style: AppTypography.mono(fontSize: 15)),
                  ]),
                ),
                const SizedBox(width: 20),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () async {
                    if (!ref.read(isLoggedInProvider)) {
                      context.push('/login');
                      return;
                    }
                    try {
                      await ref.read(postCommentRepositoryProvider).share(post.id);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(const SnackBar(content: Text('Shared')));
                      }
                    } catch (_) {}
                  },
                  child: Row(children: [
                    Transform.flip(flipX: true, child: const Icon(Icons.reply, color: AppColors.text, size: 24)),
                    const SizedBox(width: 7),
                    Text('${post.shares}', style: AppTypography.mono(fontSize: 15)),
                  ]),
                ),
              ],
            ),
          ),
          if (post.imageUrl != null && post.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.publicPostPadding, 10, AppSpacing.publicPostPadding, 0),
              child: LinkifiedText(text: post.content, style: AppTypography.sans(fontSize: 15)),
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
/// A spliced feed video that autoplays muted while on screen (Instagram
/// style) and pauses the instant it scrolls away — controlled by a
/// VisibilityDetector so only the visible one is ever decoding. A speaker
/// button toggles sound; tapping the video opens the full vertical player.
class _VideoCard extends StatefulWidget {
  const _VideoCard({required this.video});
  final VideoModel video;

  @override
  State<_VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<_VideoCard> {
  VideoPlayerController? _controller;
  bool _muted = true;
  bool _visible = false;
  bool _initializing = false;

  Future<void> _ensureInit() async {
    if (_controller != null || _initializing) return;
    _initializing = true;
    final c = VideoPlayerController.networkUrl(Uri.parse(mediaUrl(widget.video.videoUrl)));
    try {
      await c.initialize();
      await c.setLooping(true);
      await c.setVolume(_muted ? 0 : 1);
    } catch (_) {
      c.dispose();
      _initializing = false;
      return;
    }
    if (!mounted) { c.dispose(); return; }
    setState(() { _controller = c; _initializing = false; });
    if (_visible) c.play();
  }

  void _onVisibility(VisibilityInfo info) {
    final visible = info.visibleFraction > 0.6;
    if (visible == _visible) return;
    _visible = visible;
    if (visible) {
      _ensureInit();
      _controller?.play();
    } else {
      _controller?.pause();
    }
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _controller?.setVolume(_muted ? 0 : 1);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    final c = _controller;
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
                  onTap: () => context.push('/profile/${video.user.username}'),
                  child: AppAvatar(
                    size: 34,
                    ring: true,
                    imageUrl: video.user.avatarUrl != null ? mediaUrl(video.user.avatarUrl!) : null,
                    displayName: video.user.displayName,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(video.user.displayName,
                      style: AppTypography.sans(fontWeight: FontWeight.w600, fontSize: 14)),
                ),
              ],
            ),
          ),
          VisibilityDetector(
            key: Key('pubvid-${video.id}'),
            onVisibilityChanged: _onVisibility,
            child: GestureDetector(
              // A public video takes you into the vertical Shorts feed so you
              // can keep scrolling other shorts (not a single-video dead end).
              onTap: () => context.go('/'),
              child: AspectRatio(
                aspectRatio: 9 / 16,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (c != null && c.value.isInitialized)
                      FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: c.value.size.width,
                          height: c.value.size.height,
                          child: VideoPlayer(c),
                        ),
                      )
                    else
                      DecoratedBox(
                        decoration: const BoxDecoration(color: AppColors.raised),
                        child: video.thumbUrl != null
                            ? CachedNetworkImage(imageUrl: mediaUrl(video.thumbUrl!), fit: BoxFit.cover)
                            : null,
                      ),
                    // Mute / unmute — tap doesn't bubble to the open-player tap.
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: GestureDetector(
                        onTap: _toggleMute,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                          child: Icon(_muted ? Icons.volume_off : Icons.volume_up, color: Colors.white, size: 18),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (video.caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.publicPostPadding, 10, AppSpacing.publicPostPadding, 0),
              child: Text(video.caption, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTypography.sans(fontSize: 15)),
            ),
        ],
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
