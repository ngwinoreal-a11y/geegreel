import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:go_router/go_router.dart';
import '../../../core/badges_provider.dart';
import '../../../core/network/api_client.dart';
import '../../../core/prewarm.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/bottom_nav_pill.dart';
import '../../../core/widgets/brand_refresh.dart';
import '../../../core/widgets/top_toast.dart';
import '../../../core/widgets/seg_control.dart';
import '../../../core/widgets/skeleton.dart';
import '../../auth/application/auth_controller.dart';
import '../../profile/data/profile_repository.dart';
import '../../overlays/presentation/ad_comments_sheet.dart';
import '../../overlays/presentation/comments_sheet.dart';
import '../../overlays/presentation/more_options_sheet.dart';
import '../../wallet/presentation/gift_sheet.dart';
import '../application/feed_controller.dart';
import '../data/feed_repository.dart';
import '../data/video_model.dart';
import 'video_slide.dart';

/// The app's home surface — ports the video feed built inline in
/// index.html's renderInner()/loadFeed(): vertical page-snapped video feed
/// with a floating topbar (avatar / For You / Following tabs / search) and
/// the bottom nav pill.
class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> with RouteAware {
  FeedTab _tab = FeedTab.forYou;
  int _activeIndex = 0;
  int _navIndex = 1; // Feed tab active in the bottom pill by default.

  // ONE PageController PER TAB — never a single shared one. Both tabs' PageViews
  // occupy the same slot in the tree, so with a shared controller PageStorage
  // restored the OTHER tab's page index into the freshly built PageView while
  // _activeIndex had just been reset to 0. Every visible page then fell outside
  // the preload window and rendered as a black box, while slide 0 — still
  // "active" off-screen — kept playing its audio. onPageChanged never fires in
  // that state, so the feed stayed black even after switching back.
  // keepPage: false stops the page index being restored from PageStorage at all.
  final Map<FeedTab, PageController> _pageControllers = {};

  PageController _controllerFor(FeedTab tab) =>
      _pageControllers.putIfAbsent(tab, () => PageController(keepPage: false));

  // Pull-to-refresh on the first video: how far past the top the drag has gone,
  // and whether a refresh is already running.
  double _pullDistance = 0;
  bool _refreshing = false;

  /// Decodes ad media the moment the feed arrives, long before the viewer
  /// swipes down to it. Ads carry no poster frame, so an ad that starts loading
  /// when it reaches the screen shows a black panel for the whole download —
  /// the one slide in the feed guaranteed to feel slow. Fetching it up front
  /// costs one image while the viewer is still on video one.
  void _precacheAds(List<VideoModel> videos) {
    for (final v in videos) {
      if (!v.isImageAd) continue;
      precacheImage(CachedNetworkImageProvider(mediaUrl(v.videoUrl)), context)
          .catchError((_) {}); // a failed pre-cache just means it loads later
    }
  }

  Future<void> _refreshFeed() async {
    setState(() => _refreshing = true);
    _pullDistance = 0;
    try {
      ref.invalidate(feedControllerProvider(_tab));
      await ref.read(feedControllerProvider(_tab).future);
      if (mounted) {
        setState(() => _activeIndex = 0);
        final c = _controllerFor(_tab);
        if (c.hasClients) c.jumpToPage(0);
      }
    } catch (_) {
      // A failed refresh leaves the existing feed on screen — better than
      // emptying it because the network blipped.
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  // Whether the feed is the visible top-of-stack route. Another screen
  // pushed on top (single video, profile, sound, notifications...) sets
  // this false so the active slide's audio actually stops instead of
  // playing on, unheard-but-audible, underneath the new screen.
  bool _routeVisible = true;

  @override
  void initState() {
    super.initState();
    // Warm the caches for the other main screens in the background so Public /
    // Messages / Notifications / Profile open instantly on first tap.
    WidgetsBinding.instance.addPostFrameCallback((_) => prewarmCaches(ref));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    setState(() => _routeVisible = false);
  }

  @override
  void didPopNext() {
    // Feed is visible again (e.g. back from Messages): resume its video and
    // make sure the pill shows Feed as the active tab, not whatever was
    // tapped to leave.
    setState(() {
      _routeVisible = true;
      _navIndex = 1;
    });
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    for (final controller in _pageControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Ports index.html's `requireLogin(msg)` gate used throughout for guest
  /// users (like/comment/follow/message/upload/etc.) — send them to the
  /// auth screen instead of letting the API call 401.
  void _requireLogin(VoidCallback action) {
    if (ref.read(isLoggedInProvider)) {
      action();
    } else {
      context.push('/login');
    }
  }

  /// Opens the real system share sheet with a link to the video (matching the
  /// public feed's share), then confirms "Shared". The sheet is a system
  /// overlay — it never navigates the app away from the feed. Only bumps the
  /// share count / shows the toast when the user actually completed a share.
  Future<void> _share(String videoId) async {
    try {
      final url = await ref.read(feedRepositoryProvider).share(videoId);
      if (!mounted) return;
      final result = await Share.share(url, subject: 'Belople video');
      if (mounted && result.status == ShareResultStatus.success) {
        showTopToast(context, 'Shared');
      }
    } catch (_) {
      if (mounted) showTopToast(context, "Couldn't share — check your connection");
    }
  }

  /// Repost / un-repost toggle (the controller flips state + count optimistically
  /// and reverts on a real failure); we just surface the outcome.
  Future<void> _repost(String videoId) async {
    final result = await ref.read(feedControllerProvider(_tab).notifier).toggleRepost(videoId);
    if (!mounted) return;
    // Refresh my profile so the repost shows (or disappears) in my Reposts tab
    // right away — no manual reload.
    if (result == 'reposted' || result == 'unreposted') {
      final me = ref.read(authControllerProvider).valueOrNull;
      if (me != null) ref.invalidate(profileProvider(me.username));
    }
    final message = switch (result) {
      'reposted' => 'Reposted to your profile',
      'unreposted' => 'Removed from your profile',
      _ => "Couldn't repost — check your connection",
    };
    showTopToast(context, message);
  }

  /// The "+" flow: open the camera first (the user asked for + to go
  /// straight to the camera). A recorded take hands its path to the composer;
  /// the camera's gallery/photo shortcut returns 'compose' to open the
  /// composer directly for a photo/text post or a gallery pick.
  Future<void> _openCreate() async {
    final result = await context.push<String>('/camera');
    if (!mounted || result == null) return;
    if (result == 'text') {
      context.push('/compose', extra: {'mode': 'text'});
    } else if (result.startsWith('video:')) {
      context.push('/compose', extra: {'videoPath': result.substring(6)});
    } else if (result.startsWith('photo:')) {
      context.push('/compose', extra: {'imagePath': result.substring(6), 'mode': 'photo'});
    } else {
      context.push('/compose');
    }
  }

  void _onPageChanged(int index) {
    setState(() => _activeIndex = index);
    final state = ref.read(feedControllerProvider(_tab)).valueOrNull;
    if (state != null &&
        index >= state.videos.length - 3 &&
        state.nextCursor != null &&
        !state.isLoadingMore) {
      ref.read(feedControllerProvider(_tab).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(feedControllerProvider(_tab));

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          feedAsync.when(
            loading: () => const _FeedSkeleton(),
            error: (err, _) => _FeedError(
              onRetry: () => ref.invalidate(feedControllerProvider(_tab)),
            ),
            data: (state) {
              // Warm ad media for this page as soon as it lands, not when it
              // scrolls into view.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _precacheAds(state.videos);
              });
              if (state.videos.isEmpty) {
                return const Center(
                  child: Text(
                    'No videos yet',
                    style: TextStyle(color: AppColors.muted),
                  ),
                );
              }
              return NotificationListener<ScrollNotification>(
                // Pull-to-refresh on a vertical PageView: RefreshIndicator
                // can't drive a page-snapped scrollable, so the overscroll at
                // the top of the feed is measured directly. Only from the
                // first video — dragging down anywhere else is just paging.
                onNotification: (n) {
                  if (_activeIndex != 0) { _pullDistance = 0; return false; }
                  if (n is OverscrollNotification && n.overscroll < 0) {
                    _pullDistance -= n.overscroll;
                    if (_pullDistance > 110 && !_refreshing) _refreshFeed();
                  } else if (n is ScrollEndNotification) {
                    _pullDistance = 0;
                  }
                  return false;
                },
                child: PageView.builder(
                // Keyed by tab so switching tabs builds a brand-new Scrollable
                // instead of handing the other tab's scroll position to it.
                key: ValueKey(_tab),
                controller: _controllerFor(_tab),
                scrollDirection: Axis.vertical,
                // Snappy TikTok-style paging: a stiff spring so a swipe flicks
                // to the next video almost instantly instead of drifting.
                physics: const _SnappyPageScrollPhysics(),
                // Keeps the neighbouring pages built so the next video's
                // controller starts buffering before you swipe to it — the
                // swipe lands on a ready frame instead of a black loading one.
                allowImplicitScrolling: true,
                onPageChanged: _onPageChanged,
                itemCount: state.videos.length,
                itemBuilder: (context, index) {
                  // Preload ring: only mount the controller for the active
                  // slide +/-1 — matches warmNeighbours()'s windowed
                  // preload rather than keeping every loaded slide alive.
                  final withinWindow = (index - _activeIndex).abs() <= 1;
                  final video = state.videos[index];
                  if (!withinWindow) {
                    // Outside the preload ring: show the poster frame rather
                    // than a bare black box, so if the window and the viewport
                    // ever disagree the user sees the video, not a dead screen.
                    return video.thumbUrl != null
                        ? CachedNetworkImage(imageUrl: mediaUrl(video.thumbUrl!), fit: BoxFit.cover)
                        : const ColoredBox(color: Colors.black);
                  }
                  return RepaintBoundary(
                    child: VideoSlide(
                    // Keyed by video id, NOT by list position. Posting a new
                    // video prepends it, so every video shifts down a slot;
                    // without a key Flutter reuses the State at that slot and
                    // the slide kept the previous video's player and counts —
                    // a fresh upload appeared with someone else's likes and
                    // comments until the app was restarted.
                    key: ValueKey(video.id),
                    video: video,
                    isActive: index == _activeIndex && _routeVisible,
                    onLikeTap: () => _requireLogin(() => video.isAd
                        ? ref.read(feedControllerProvider(_tab).notifier).adToggleLike(video.id)
                        : ref.read(feedControllerProvider(_tab).notifier).toggleLike(video.id)),
                    // Records the CTA click on a user ad (best-effort).
                    onAdClick: () => ref.read(feedRepositoryProvider).recordAdClick(video.id),
                    onFollowTap: () => _requireLogin(() => ref
                        .read(feedControllerProvider(_tab).notifier)
                        .toggleFollow(video.user.id)),
                    onAuthorTap: () => context.push('/profile/${video.user.username}'),
                    onCommentTap: () => video.isAd
                        ? showAdCommentsSheet(context, adId: video.id)
                        : showCommentsSheet(context, videoId: video.id),
                    onMoreTap: () => _requireLogin(
                        () => showMoreOptionsSheet(context, ref, video: video,
                            onDeleted: () => ref
                                .read(feedControllerProvider(_tab).notifier)
                                .removeVideo(video.id))),
                    // Matches the web: only a shareable sound (has a soundId)
                    // is tappable, opening its page. An original sound isn't a
                    // link at all — no profile detour.
                    onSoundTap: video.soundId != null
                        ? () => context.push('/sound/${video.soundId}')
                        : null,
                    onShareTap: () => _share(video.id),
                    onGiftTap: () =>
                        _requireLogin(() => showGiftSheet(context, videoId: video.id)),
                    onRepostTap: () => _requireLogin(() => _repost(video.id)),
                  ),
                  );
                },
              ),
              );
            },
          ),

          // Refresh indicator for the pull gesture above.
          if (_refreshing)
            Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 70),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const BrandRefreshDots(),
                    ),
                  ),
                ),
              ),
            ),

          // Top chrome: avatar, For You / Following tabs, search — floats
          // on the picture, no backdrop (design-feed.css section B).
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    Builder(builder: (context) {
                      final me = ref.watch(authControllerProvider).valueOrNull;
                      return GestureDetector(
                        onTap: () => _requireLogin(() => context.push('/profile/${me!.username}')),
                        child: AppAvatar(
                          size: 44,
                          ring: true,
                          imageUrl: me?.avatarUrl != null ? mediaUrl(me!.avatarUrl!) : null,
                          displayName: me?.displayName ?? '?',
                          backgroundColor: AppColors.chrome,
                          textColor: AppColors.onChrome,
                        ),
                      );
                    }),
                    const SizedBox(width: 8),
                    // FittedBox scales the tabs down to fit the row rather than
                    // clipping the last one off-screen (which made "Public"
                    // untappable). Notifications live on the profile header.
                    Expanded(
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: FeedTabs(
                            labels: const ['Following', 'Belo', 'Public'],
                            selectedIndex: _tab == FeedTab.following ? 0 : 1,
                            onChanged: (i) {
                              if (i == 2) {
                                context.push('/public');
                                return;
                              }
                              final next = i == 0 ? FeedTab.following : FeedTab.forYou;
                              if (next == _tab) return;
                              setState(() {
                                _tab = next;
                                _activeIndex = 0;
                              });
                              // The new tab's controller may not be attached yet
                              // (its PageView builds on the next frame, and the
                              // tab can open on a skeleton/empty state) — jumping
                              // an unattached controller throws.
                              final controller = _controllerFor(next);
                              if (controller.hasClients) controller.jumpToPage(0);
                            },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => context.push('/search'),
                      child: const Icon(
                        Icons.search,
                        color: Colors.white,
                        size: 32,
                        shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom nav pill.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: BottomNavPill(
              items: const [
                (icon: Icons.mail_outline, label: 'Messages'),
                (icon: Icons.videocam, label: 'Shorts'),
              ],
              badges: [ref.watch(unreadMessagesProvider).valueOrNull ?? 0, 0],
              activeIndex: _navIndex,
              onTap: (i) {
                if (i == 0) {
                  _requireLogin(() => context.push('/messages'));
                } else {
                  // Already on Feed — tap Feed/home again to jump to the top
                  // of the feed (matches the web app's re-tap behaviour).
                  setState(() => _navIndex = 1);
                  final controller = _controllerFor(_tab);
                  if (controller.hasClients) {
                    controller.jumpToPage(0);
                    setState(() => _activeIndex = 0);
                  }
                }
              },
              fabIcon: Icons.add,
              onFabTap: () => _requireLogin(_openCreate),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedSkeleton extends StatelessWidget {
  const _FeedSkeleton();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: AppColors.skBase),
        Positioned(
          left: 16,
          right: 88,
          bottom: 96,
          child: Row(
            children: const [
              Skeleton.avatar(size: 44),
              SizedBox(width: 10),
              Expanded(child: Skeleton(height: 12)),
            ],
          ),
        ),
      ],
    );
  }
}

class _FeedError extends StatelessWidget {
  const _FeedError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "Couldn't load the feed",
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 12),
          TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}

/// TikTok-style paging: keep normal page-snapping, but swap the settle spring
/// for a much stiffer one so a swipe flicks to the next video almost instantly
/// instead of drifting up slowly. Higher stiffness + lower mass = a fast snap;
/// damping ~1 keeps it clean with no bounce/overshoot.
class _SnappyPageScrollPhysics extends PageScrollPhysics {
  const _SnappyPageScrollPhysics({super.parent});

  @override
  _SnappyPageScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _SnappyPageScrollPhysics(parent: buildParent(ancestor));

  // withDampingRatio, NOT a raw damping coefficient: ratio 1.0 is critically
  // damped — the fastest snap that DOESN'T overshoot. (The old raw damping of
  // 1.0 was far below critical for this mass/stiffness, so the page sprang up
  // then bounced/vibrated several times before settling.) High stiffness keeps
  // the flick fast; ratio 1.0 makes it land once and stop dead.
  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
        // Much stiffer + lighter than before so the page snaps up fast and the
        // spring's settle tail is over almost instantly — that long, slow
        // final approach was the "catch"/drag felt at the end. ratio 1.0 keeps
        // it critically damped (fast, firm, no overshoot or bounce).
        mass: 0.3,
        stiffness: 560,
        ratio: 1.0,
      );
}
