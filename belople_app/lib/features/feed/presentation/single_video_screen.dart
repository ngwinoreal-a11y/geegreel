import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/bottom_nav_pill.dart';
import '../../../core/widgets/top_toast.dart';
import '../../auth/application/auth_controller.dart';
import '../../overlays/presentation/comments_sheet.dart';
import '../../overlays/presentation/more_options_sheet.dart';
import '../../wallet/presentation/gift_sheet.dart';
import '../data/feed_repository.dart';
import '../data/video_model.dart';
import 'video_slide.dart';

final singleVideoProvider = FutureProvider.family.autoDispose<VideoModel, String>((ref, id) async {
  final res = await ref.watch(dioProvider).get('/videos/$id');
  return VideoModel.fromJson((res.data as Map<String, dynamic>)['video'] as Map<String, dynamic>);
});

/// Opening one video — from Public, a share link, a notification, a sound page.
///
/// It starts ON that video but is the full Shorts surface, not a dead end: the
/// Belo feed is loaded in behind it so the viewer can keep swiping, and the
/// bottom nav stays where it always is. Landing somewhere you can only back out
/// of is the thing this screen used to get wrong.
class SingleVideoScreen extends ConsumerStatefulWidget {
  const SingleVideoScreen({
    super.key,
    required this.videoId,
    this.initialVideo,
    this.openComments = false,
  });
  final String videoId;

  /// Open the comments sheet on arrival — used by comment/reply notifications.
  final bool openComments;

  /// Passed when we already hold the video (tapped in a grid or the public
  /// feed) so the player shows immediately instead of spinning on a refetch.
  final VideoModel? initialVideo;

  @override
  ConsumerState<SingleVideoScreen> createState() => _SingleVideoScreenState();
}

class _SingleVideoScreenState extends ConsumerState<SingleVideoScreen> with RouteAware {
  final PageController _controller = PageController();
  final List<VideoModel> _videos = [];
  int _active = 0;
  bool _routeVisible = true;
  bool _loadingMore = false;
  String? _cursor;
  bool _exhausted = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialVideo != null) _videos.add(widget.initialVideo!);
    _loadMore();
    if (widget.openComments) {
      // After the first frame: the sheet needs a mounted route to open onto.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showCommentsSheet(context, videoId: widget.videoId);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) routeObserver.subscribe(this, route);
  }

  @override
  void didPushNext() => setState(() => _routeVisible = false);
  @override
  void didPopNext() => setState(() => _routeVisible = true);

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _controller.dispose();
    super.dispose();
  }

  /// Pulls the next page of the Belo feed and appends it, skipping anything
  /// already on screen so the same clip can't appear twice.
  Future<void> _loadMore() async {
    if (_loadingMore || _exhausted) return;
    _loadingMore = true;
    try {
      final page = await ref.read(feedRepositoryProvider).fetchFeed(tab: 'belo', cursor: _cursor);
      if (!mounted) return;
      final seen = _videos.map((v) => v.id).toSet();
      final fresh = page.videos.where((v) => !seen.contains(v.id)).toList();
      setState(() {
        _videos.addAll(fresh);
        _cursor = page.nextCursor;
        _exhausted = page.nextCursor == null;
      });
    } catch (_) {
      _exhausted = true; // no more feed; the opened video still plays
    } finally {
      _loadingMore = false;
    }
  }

  void _onPageChanged(int i) {
    setState(() => _active = i);
    if (i >= _videos.length - 3) _loadMore();
  }

  void _requireLogin(VoidCallback action) {
    if (ref.read(isLoggedInProvider)) {
      action();
    } else {
      context.push('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Nothing to show yet: either we arrived without a video (share link,
    // notification) or the fetch is still in flight.
    if (_videos.isEmpty) {
      final async = ref.watch(singleVideoProvider(widget.videoId));
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: async.when(
          loading: () => const Center(child: CircularProgressIndicator(color: AppColors.text)),
          error: (e, _) => Center(
            child: Text(
              e is DioException && e.response?.statusCode == 404
                  ? 'Video not found'
                  : "Couldn't load this video",
              style: const TextStyle(color: AppColors.muted),
            ),
          ),
          data: (v) {
            // Seed the list once the fetch lands, then rebuild as a feed.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _videos.isEmpty) setState(() => _videos.insert(0, v));
            });
            return const Center(child: CircularProgressIndicator(color: AppColors.text));
          },
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            scrollDirection: Axis.vertical,
            allowImplicitScrolling: true,
            onPageChanged: _onPageChanged,
            itemCount: _videos.length,
            itemBuilder: (context, i) {
              final video = _videos[i];
              return RepaintBoundary(
                child: VideoSlide(
                  key: ValueKey(video.id),
                  video: video,
                  isActive: i == _active && _routeVisible,
                  onLikeTap: () => _requireLogin(
                      () => ref.invalidate(singleVideoProvider(video.id))),
                  onCommentTap: () => showCommentsSheet(context, videoId: video.id),
                  onAuthorTap: () => context.push('/profile/${video.user.username}'),
                  onSoundTap: video.soundId != null
                      ? () => context.push('/sound/${video.soundId}')
                      : null,
                  onGiftTap: () => _requireLogin(() => showGiftSheet(context, videoId: video.id)),
                  onRepostTap: () => _requireLogin(() => _repost(video.id)),
                  onShareTap: () => _share(video.id),
                  onMoreTap: () => _requireLogin(() => showMoreOptionsSheet(
                        context, ref,
                        video: video,
                        onDeleted: () => setState(() => _videos.removeWhere((v) => v.id == video.id)),
                      )),
                ),
              );
            },
          ),
          SafeArea(
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          // The same nav as everywhere else — this is the Shorts surface, so it
          // shouldn't feel like a different place with no way out but Back.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: BottomNavPill(
              items: const [
                (icon: Icons.mail_outline, label: 'Messages'),
                (icon: Icons.videocam, label: 'Shorts'),
              ],
              activeIndex: 1,
              onTap: (i) {
                if (i == 0) {
                  _requireLogin(() => context.push('/messages'));
                } else if (_controller.hasClients) {
                  _controller.jumpToPage(0);
                  setState(() => _active = 0);
                }
              },
              fabIcon: Icons.add,
              onFabTap: () => _requireLogin(() => context.push('/camera')),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _repost(String videoId) async {
    try {
      await ref.read(feedRepositoryProvider).repost(videoId);
      if (mounted) showTopToast(context, 'Reposted to your profile');
    } on DioException catch (e) {
      if (mounted) {
        showTopToast(context,
            e.response?.statusCode == 409 ? 'You already reposted this' : "Couldn't repost");
      }
    }
  }

  Future<void> _share(String videoId) async {
    try {
      final url = await ref.read(feedRepositoryProvider).share(videoId);
      if (!mounted) return;
      final result = await Share.share(url, subject: 'Belople video');
      if (mounted && result.status == ShareResultStatus.success) {
        showTopToast(context, 'Shared');
      }
    } catch (_) {}
  }
}
