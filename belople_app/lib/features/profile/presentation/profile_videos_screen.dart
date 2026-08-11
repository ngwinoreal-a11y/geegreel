import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/top_toast.dart';
import '../../auth/application/auth_controller.dart';
import '../../feed/data/feed_repository.dart';
import '../../feed/data/video_model.dart';
import '../../feed/presentation/video_slide.dart';
import '../../overlays/presentation/comments_sheet.dart';
import '../../overlays/presentation/more_options_sheet.dart';
import '../../wallet/presentation/gift_sheet.dart';

/// Opening a video from a profile grid shows a vertical, swipeable feed of that
/// profile's videos starting at the tapped one — not a single dead-end clip.
/// Reuses the home feed's VideoSlide renderer.
class ProfileVideosScreen extends ConsumerStatefulWidget {
  const ProfileVideosScreen({super.key, required this.videos, required this.initialIndex});
  final List<VideoModel> videos;
  final int initialIndex;

  @override
  ConsumerState<ProfileVideosScreen> createState() => _ProfileVideosScreenState();
}

class _ProfileVideosScreenState extends ConsumerState<ProfileVideosScreen> with RouteAware {
  late final PageController _controller = PageController(initialPage: widget.initialIndex);
  late int _active = widget.initialIndex;
  bool _routeVisible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) routeObserver.subscribe(this, route);
  }

  // Pause this feed's audio/video whenever another screen covers it.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            scrollDirection: Axis.vertical,
            itemCount: widget.videos.length,
            onPageChanged: (i) => setState(() => _active = i),
            itemBuilder: (context, i) => _slide(widget.videos[i], i == _active && _routeVisible),
          ),
          SafeArea(
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _slide(VideoModel video, bool isActive) {
    return VideoSlide(
      // Per-video State, so swiping never lands on a slide still holding the
      // previous video's player or counts.
      key: ValueKey(video.id),
      video: video,
      isActive: isActive,
      onLikeTap: () {
        if (!ref.read(isLoggedInProvider)) context.push('/login');
      },
      onCommentTap: () => showCommentsSheet(context, videoId: video.id),
      onAuthorTap: () => context.push('/profile/${video.user.username}'),
      onSoundTap: video.soundId != null ? () => context.push('/sound/${video.soundId}') : null,
      onGiftTap: () {
        if (!ref.read(isLoggedInProvider)) {
          context.push('/login');
        } else {
          showGiftSheet(context, videoId: video.id);
        }
      },
      onRepostTap: () async {
        if (!ref.read(isLoggedInProvider)) { context.push('/login'); return; }
        try {
          await ref.read(feedRepositoryProvider).repost(video.id);
          if (mounted) showTopToast(context, 'Reposted to your profile');
        } on DioException catch (e) {
          if (mounted) {
            showTopToast(context, e.response?.statusCode == 409 ? 'You already reposted this' : "Couldn't repost");
          }
        }
      },
      onShareTap: () async {
        try {
          final url = await ref.read(feedRepositoryProvider).share(video.id);
          if (!mounted) return;
          final result = await Share.share(url, subject: 'Belople video');
          if (mounted && result.status == ShareResultStatus.success) {
            showTopToast(context, 'Shared');
          }
        } catch (_) {}
      },
      onMoreTap: () {
        if (!ref.read(isLoggedInProvider)) {
          context.push('/login');
        } else {
          showMoreOptionsSheet(context, ref, video: video, onDeleted: () => Navigator.of(context).maybePop());
        }
      },
    );
  }
}
