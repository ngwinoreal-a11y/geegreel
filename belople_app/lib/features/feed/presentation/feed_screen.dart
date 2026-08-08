import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/bottom_nav_pill.dart';
import '../../../core/widgets/seg_control.dart';
import '../../../core/widgets/skeleton.dart';
import '../../auth/application/auth_controller.dart';
import '../../overlays/presentation/comments_sheet.dart';
import '../../overlays/presentation/more_options_sheet.dart';
import '../../wallet/presentation/gift_sheet.dart';
import '../application/feed_controller.dart';
import '../data/feed_repository.dart';
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
  late final PageController _pageController;
  int _navIndex = 1; // Feed tab active in the bottom pill by default.

  // Whether the feed is the visible top-of-stack route. Another screen
  // pushed on top (single video, profile, sound, notifications...) sets
  // this false so the active slide's audio actually stops instead of
  // playing on, unheard-but-audible, underneath the new screen.
  bool _routeVisible = true;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
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
    _pageController.dispose();
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

  /// Ports the "Link copied" flow — design-4.css's copy rules: "Share does
  /// not 'share' anything by itself — it hands back a link... the honest
  /// label for the copy action is 'Link copied'."
  Future<void> _share(String videoId) async {
    try {
      final url = await ref.read(feedRepositoryProvider).share(videoId);
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("Couldn't share — check your connection")));
      }
    }
  }

  /// Reposts a video to the caller's profile, surfacing the "already
  /// reposted" case the backend reports as a 409 (design-4.css copy rule).
  Future<void> _repost(String videoId) async {
    try {
      await ref.read(feedRepositoryProvider).repost(videoId);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Reposted to your profile')));
      }
    } on DioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.response?.statusCode == 409
              ? 'You already reposted this'
              : "Couldn't repost — check your connection"),
        ));
      }
    }
  }

  /// The "+" flow: open the camera first (the user asked for + to go
  /// straight to the camera). A recorded take hands its path to the composer;
  /// the camera's gallery/photo shortcut returns 'compose' to open the
  /// composer directly for a photo/text post or a gallery pick.
  Future<void> _openCreate() async {
    final result = await context.push<String>('/camera');
    if (!mounted || result == null) return;
    if (result == 'compose') {
      context.push('/compose');
    } else {
      context.push('/compose', extra: {'videoPath': result});
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
              if (state.videos.isEmpty) {
                return const Center(
                  child: Text(
                    'No videos yet',
                    style: TextStyle(color: AppColors.muted),
                  ),
                );
              }
              return PageView.builder(
                controller: _pageController,
                scrollDirection: Axis.vertical,
                onPageChanged: _onPageChanged,
                itemCount: state.videos.length,
                itemBuilder: (context, index) {
                  // Preload ring: only mount the controller for the active
                  // slide +/-1 — matches warmNeighbours()'s windowed
                  // preload rather than keeping every loaded slide alive.
                  final withinWindow = (index - _activeIndex).abs() <= 1;
                  if (!withinWindow) {
                    return const ColoredBox(color: Colors.black);
                  }
                  final video = state.videos[index];
                  return VideoSlide(
                    video: video,
                    isActive: index == _activeIndex && _routeVisible,
                    onLikeTap: () => _requireLogin(() =>
                        ref.read(feedControllerProvider(_tab).notifier).toggleLike(video.id)),
                    onFollowTap: () => _requireLogin(() => ref
                        .read(feedControllerProvider(_tab).notifier)
                        .toggleFollow(video.user.id)),
                    onAuthorTap: () => context.push('/profile/${video.user.username}'),
                    onCommentTap: () => showCommentsSheet(context, videoId: video.id),
                    onMoreTap: () => _requireLogin(
                        () => showMoreOptionsSheet(context, ref, video: video)),
                    onSoundTap: video.soundId != null
                        ? () => context.push('/sound/${video.soundId}')
                        : null,
                    onShareTap: () => _share(video.id),
                    onGiftTap: () =>
                        _requireLogin(() => showGiftSheet(context, videoId: video.id)),
                    onRepostTap: () => _requireLogin(() => _repost(video.id)),
                  );
                },
              );
            },
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
                          imageUrl: me?.avatarUrl != null ? mediaUrl(me!.avatarUrl!) : null,
                          displayName: me?.displayName ?? '?',
                          backgroundColor: AppColors.chrome,
                          textColor: AppColors.onChrome,
                        ),
                      );
                    }),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Center(
                        child: FeedTabs(
                          labels: const ['Following', 'For you', 'Public'],
                          selectedIndex: _tab == FeedTab.following ? 0 : 1,
                          onChanged: (i) {
                            if (i == 2) {
                              context.push('/public');
                              return;
                            }
                            setState(() {
                              _tab = i == 0 ? FeedTab.following : FeedTab.forYou;
                              _activeIndex = 0;
                            });
                            _pageController.jumpToPage(0);
                          },
                        ),
                      ),
                    ),
                    // Search & notifications moved next to Settings on the
                    // profile screen — the feed header is just the avatar and
                    // the big Following / For you / Public tabs now.
                    const SizedBox(width: 44),
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
                (icon: Icons.home_rounded, label: 'Feed'),
              ],
              activeIndex: _navIndex,
              onTap: (i) {
                if (i == 0) {
                  _requireLogin(() => context.push('/messages'));
                } else {
                  // Already on Feed — tap Feed/home again to jump to the top
                  // of the feed (matches the web app's re-tap behaviour).
                  setState(() => _navIndex = 1);
                  if (_pageController.hasClients) {
                    _pageController.jumpToPage(0);
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
