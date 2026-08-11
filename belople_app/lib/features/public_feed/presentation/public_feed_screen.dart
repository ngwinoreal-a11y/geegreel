import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/brand_refresh.dart';
import '../../../core/widgets/brand_wordmark.dart';
import '../../../core/widgets/linkified_text.dart';
import '../../../core/widgets/skeleton.dart';
import '../../auth/application/auth_controller.dart';
import '../../feed/data/feed_repository.dart';
import '../../feed/data/video_model.dart';
import '../application/public_feed_controller.dart';
import '../data/post_model.dart';
import 'post_comments_sheet.dart';

/// Compact "time ago" for a post's age — matches the web's "4d", "3h", "just
/// now" style shown next to the author.
String _timeAgo(DateTime when) {
  final d = DateTime.now().difference(when);
  if (d.inSeconds < 60) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  if (d.inDays < 30) return '${(d.inDays / 7).floor()}w';
  if (d.inDays < 365) return '${(d.inDays / 30).floor()}mo';
  return '${(d.inDays / 365).floor()}y';
}

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

  /// Sound is a decision about the FEED, not about one card: unmuting a video
  /// means "I want to hear this feed", so every later video keeps playing with
  /// sound, and muting again silences them all. Held in the screen's own State
  /// so it lasts exactly as long as Public is open — leaving the page drops it
  /// and the feed starts muted again, the way the user expects.
  bool _soundOn = false;

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

  /// Reaching for the phone's volume rocker while a muted preview is playing
  /// means "let me hear this" — so it turns the feed's sound on, the way the
  /// other photo/video feeds people use behave. The event is deliberately NOT
  /// consumed: Android must still change the actual system volume.
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    final k = event.logicalKey;
    if (event is KeyDownEvent &&
        (k == LogicalKeyboardKey.audioVolumeUp || k == LogicalKeyboardKey.audioVolumeDown) &&
        !_soundOn) {
      setState(() => _soundOn = true);
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(publicFeedControllerProvider);

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
      // Public is a light surface (a deliberate break from the app's dark
      // theme, like the white Messages inbox) — white page, dark ink.
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        foregroundColor: AppColors.onChrome,
        elevation: 0,
        centerTitle: true,
        title: const BrandWordmark(),
      ),
      body: feedAsync.when(
        loading: () => ListView.builder(
          itemCount: 3,
          itemBuilder: (context, i) => const _PostSkeleton(),
        ),
        error: (e, _) => Center(
          child: Text("Couldn't load posts", style: AppTypography.sans(color: AppColors.onChromeMuted)),
        ),
        data: (state) {
          if (state.posts.isEmpty) {
            return Center(child: Text('No posts yet', style: AppTypography.sans(color: AppColors.onChromeMuted)));
          }
          final items = _interleave(state.posts);
          return BrandRefresh(
            onRefresh: () async {
              ref.invalidate(publicFeedControllerProvider);
              await ref.read(publicFeedControllerProvider.future);
            },
            child: ListView.builder(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              if (item is _VideoItem) {
                return _VideoCard(
                  video: item.video,
                  soundOn: _soundOn,
                  onSoundToggle: () => setState(() => _soundOn = !_soundOn),
                );
              }
              final post = (item as _PostItem).post;
              return _PostCard(
                post: post,
                onLikeTap: () =>
                    ref.read(publicFeedControllerProvider.notifier).toggleLike(post.id),
              );
            },
            ),
          );
        },
      ),
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
    final me = ref.watch(authControllerProvider).valueOrNull;
    final isMine = me != null && me.id == post.user.id;
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
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(post.user.displayName,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.sans(fontWeight: FontWeight.w600, fontSize: 14, color: AppColors.onChrome)),
                        ),
                        // Blue tick only for the official/admin (Belople) account.
                        if (post.user.verified) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.verified, color: AppColors.verified, size: 15),
                        ],
                        const SizedBox(width: 8),
                        Text(_timeAgo(post.createdAt),
                            style: AppTypography.sans(fontSize: 12, color: AppColors.onChromeMuted)),
                      ],
                    ),
                  ),
                ),
                if (!isMine)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (!ref.read(isLoggedInProvider)) {
                        context.push('/login');
                        return;
                      }
                      ref
                          .read(publicFeedControllerProvider.notifier)
                          .toggleFollow(post.user.id, post.following);
                    },
                    child: Text(
                      post.following ? 'Following' : 'Follow',
                      style: AppTypography.sans(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: post.following ? AppColors.onChromeMuted : AppColors.verified,
                      ),
                    ),
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
                decoration: BoxDecoration(color: const Color(0xFFF5F5F6), borderRadius: BorderRadius.circular(14)),
                child: LinkifiedText(text: post.content, style: AppTypography.sans(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.onChrome)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.publicPostPadding, 12, AppSpacing.publicPostPadding, 0),
            child: Row(
              children: [
                GestureDetector(
                  // Opaque like the comment/share buttons beside it — without
                  // this the gaps in the row swallow taps and the like feels
                  // dead unless you hit the glyph exactly.
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (!ref.read(isLoggedInProvider)) {
                      context.push('/login');
                    } else {
                      onLikeTap();
                    }
                  },
                  child: Row(children: [
                    Icon(post.liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        color: post.liked ? AppColors.badge : AppColors.onChrome, size: 26),
                    const SizedBox(width: 7),
                    Text('${post.likes}', style: AppTypography.mono(fontSize: 15, color: AppColors.onChrome)),
                  ]),
                ),
                const SizedBox(width: 20),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => showPostCommentsSheet(context, postId: post.id),
                  child: Row(children: [
                    const Icon(Icons.mode_comment_outlined, color: AppColors.onChrome, size: 24),
                    const SizedBox(width: 7),
                    Text('${post.comments}', style: AppTypography.mono(fontSize: 15, color: AppColors.onChrome)),
                  ]),
                ),
                const SizedBox(width: 20),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () async {
                    // Open the real system share sheet with a link to the post
                    // (matches public.js's share()), then bump the count.
                    await Share.share('$kApiBaseUrl/p/${post.id}', subject: 'Belople post');
                    ref.read(publicFeedControllerProvider.notifier).registerShare(post.id);
                  },
                  child: Row(children: [
                    const Icon(Icons.send_rounded, color: AppColors.onChrome, size: 23),
                    const SizedBox(width: 7),
                    Text('${post.shares}', style: AppTypography.mono(fontSize: 15, color: AppColors.onChrome)),
                  ]),
                ),
              ],
            ),
          ),
          if (post.imageUrl != null && post.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.publicPostPadding, 10, AppSpacing.publicPostPadding, 0),
              child: LinkifiedText(text: post.content, style: AppTypography.sans(fontSize: 15, color: AppColors.onChrome)),
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
  const _VideoCard({
    required this.video,
    required this.soundOn,
    required this.onSoundToggle,
  });
  final VideoModel video;

  /// Feed-wide sound setting (see _PublicFeedScreenState._soundOn).
  final bool soundOn;
  final VoidCallback onSoundToggle;

  @override
  State<_VideoCard> createState() => _VideoCardState();
}

/// How long a video has to hold the screen before we offer the way into the
/// full Shorts feed.
const _watchMoreAfter = Duration(seconds: 8);

class _VideoCardState extends State<_VideoCard> {
  VideoPlayerController? _controller;
  bool _visible = false;
  bool _initializing = false;

  /// "Watch more videos" nudge, shown once the viewer has stayed on this video
  /// for _watchMoreAfter without tapping it.
  Timer? _watchMoreTimer;
  bool _showWatchMore = false;

  Future<void> _ensureInit() async {
    if (_controller != null || _initializing) return;
    _initializing = true;
    final c = VideoPlayerController.networkUrl(Uri.parse(mediaUrl(widget.video.videoUrl)));
    try {
      await c.initialize();
      await c.setLooping(true);
    } catch (_) {
      c.dispose();
      _initializing = false;
      return;
    }
    if (!mounted) { c.dispose(); return; }
    setState(() { _controller = c; _initializing = false; });
    _applyVolume();
    _applyPlayback();
  }

  /// Only the card actually on screen may be heard — so scrolling past an
  /// unmuted video hands the sound to the next one instead of stacking two.
  void _applyVolume() {
    _controller?.setVolume(widget.soundOn && _visible ? 1 : 0);
  }

  @override
  void didUpdateWidget(covariant _VideoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The feed-wide sound setting changed (this card's speaker, or another
    // card's, was tapped) — follow it.
    if (widget.soundOn != oldWidget.soundOn) _applyVolume();
  }

  void _onVisibility(VisibilityInfo info) {
    // Start fetching/decoding the moment ANY sliver of the card enters the
    // viewport, not at the 60% play threshold. By the time it's centred the
    // first frame is ready, so it starts instantly instead of showing a dead
    // panel while the network catches up.
    if (info.visibleFraction > 0.01) _ensureInit();

    final visible = info.visibleFraction > 0.6;
    if (visible == _visible) return;
    _visible = visible;
    if (visible) {
      _startWatchMoreTimer();
    } else {
      _cancelWatchMore();
    }
    _applyPlayback();
    _applyVolume();
  }

  /// The card plays only while it's on screen AND the nudge isn't up — once
  /// "Watch more videos" appears the preview stops, so the choice is to tap
  /// through rather than keep half-watching a muted loop in a scroll feed.
  void _applyPlayback() {
    final c = _controller;
    if (c == null) return;
    if (_visible && !_showWatchMore) {
      if (!c.value.isPlaying) c.play();
    } else {
      if (c.value.isPlaying) c.pause();
    }
  }

  void _startWatchMoreTimer() {
    _watchMoreTimer?.cancel();
    _watchMoreTimer = Timer(_watchMoreAfter, () {
      if (!mounted) return;
      setState(() => _showWatchMore = true);
      _applyPlayback(); // the nudge is up — hold the video here
    });
  }

  void _cancelWatchMore() {
    _watchMoreTimer?.cancel();
    _watchMoreTimer = null;
    if (_showWatchMore && mounted) setState(() => _showWatchMore = false);
  }

  @override
  void dispose() {
    _watchMoreTimer?.cancel();
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
                      style: AppTypography.sans(fontWeight: FontWeight.w600, fontSize: 14, color: AppColors.onChrome)),
                ),
              ],
            ),
          ),
          VisibilityDetector(
            key: Key('pubvid-${video.id}'),
            onVisibilityChanged: _onVisibility,
            child: GestureDetector(
              // Opens THIS video full-screen. It used to send you to the top of
              // the Shorts feed, which threw away the video actually tapped.
              onTap: () => context.push('/v/${video.id}', extra: video),
              child: AspectRatio(
                aspectRatio: 9 / 16,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // The poster stays UNDERNEATH the player for the card's whole
                    // life — not swapped out for it. Any gap (still buffering, a
                    // frame dropped on a seek/loop) then shows the picture rather
                    // than a black panel.
                    DecoratedBox(
                      decoration: const BoxDecoration(color: AppColors.raised),
                      child: video.thumbUrl != null
                          ? CachedNetworkImage(imageUrl: mediaUrl(video.thumbUrl!), fit: BoxFit.cover)
                          : null,
                    ),
                    if (c != null && c.value.isInitialized)
                      FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: c.value.size.width,
                          height: c.value.size.height,
                          child: VideoPlayer(c),
                        ),
                      ),

                    // "Watch more videos" — appears in the MIDDLE of the frame
                    // once the viewer has stayed with this video a while, and
                    // the video holds there (see _applyPlayback). Tapping
                    // anywhere on the card opens it full-screen, so the nudge
                    // itself stays non-interactive.
                    IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _showWatchMore ? 1 : 0,
                        duration: const Duration(milliseconds: 260),
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.66),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 22),
                                const SizedBox(width: 8),
                                Text('Watch more videos',
                                    style: AppTypography.sans(
                                        fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    // Sound on / off for the WHOLE feed — tap doesn't bubble to
                    // the open-player tap.
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onSoundToggle,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                          child: Icon(widget.soundOn ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                              color: Colors.white, size: 18),
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
              child: Text(video.caption, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTypography.sans(fontSize: 15, color: AppColors.onChrome)),
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
