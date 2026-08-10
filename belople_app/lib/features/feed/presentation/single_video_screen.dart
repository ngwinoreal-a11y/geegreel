import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
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

/// Ports index.html's userFeedPage() single-slide case: opened from a
/// profile grid cell, sound page, share link, or notification — reuses the
/// same VideoSlide renderer as the home feed.
class SingleVideoScreen extends ConsumerWidget {
  const SingleVideoScreen({super.key, required this.videoId, this.initialVideo});
  final String videoId;

  /// Passed when we already have the video (e.g. from a profile grid) so the
  /// player shows immediately with no loading spinner. Falls back to fetching.
  final VideoModel? initialVideo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final videoAsync = ref.watch(singleVideoProvider(videoId));
    // Render the passed-in video right away; only fall back to the fetch's
    // loading/error states when we arrived here without one (share link,
    // notification, etc.).
    final video = videoAsync.valueOrNull ?? initialVideo;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: video == null
          ? videoAsync.when(
              loading: () => const Center(child: CircularProgressIndicator(color: AppColors.text)),
              error: (e, _) => Center(
                child: Text(
                  e is DioException && e.response?.statusCode == 404 ? 'Video not found' : "Couldn't load this video",
                  style: const TextStyle(color: AppColors.muted),
                ),
              ),
              data: (v) => const SizedBox.shrink(),
            )
          : _player(context, ref, video),
    );
  }

  Widget _player(BuildContext context, WidgetRef ref, VideoModel video) {
    return Stack(
          children: [
            VideoSlide(
              video: video,
              isActive: true,
              onLikeTap: () {
                if (!ref.read(isLoggedInProvider)) return;
                ref.invalidate(singleVideoProvider(videoId));
              },
              onCommentTap: () => showCommentsSheet(context, videoId: video.id),
              onAuthorTap: () => context.push('/profile/${video.user.username}'),
              onSoundTap: video.soundId != null
                  ? () => context.push('/sound/${video.soundId}')
                  : null,
              onGiftTap: () {
                if (!ref.read(isLoggedInProvider)) {
                  context.push('/login');
                } else {
                  showGiftSheet(context, videoId: video.id);
                }
              },
              onRepostTap: () async {
                if (!ref.read(isLoggedInProvider)) {
                  context.push('/login');
                  return;
                }
                try {
                  await ref.read(feedRepositoryProvider).repost(video.id);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Reposted to your profile')));
                  }
                } on DioException catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(e.response?.statusCode == 409
                          ? 'You already reposted this'
                          : "Couldn't repost"),
                    ));
                  }
                }
              },
              onShareTap: () async {
                try {
                  final url = await ref.read(feedRepositoryProvider).share(video.id);
                  if (!context.mounted) return;
                  final result = await Share.share(url, subject: 'Belople video');
                  if (context.mounted && result.status == ShareResultStatus.success) {
                    showTopToast(context, 'Shared');
                  }
                } catch (_) {}
              },
              onMoreTap: () {
                if (!ref.read(isLoggedInProvider)) {
                  context.push('/login');
                } else {
                  showMoreOptionsSheet(context, ref, video: video,
                      onDeleted: () => Navigator.of(context).maybePop());
                }
              },
            ),
            SafeArea(
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
    );
  }
}
