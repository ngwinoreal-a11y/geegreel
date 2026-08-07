import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../auth/application/auth_controller.dart';
import '../../overlays/presentation/comments_sheet.dart';
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
  const SingleVideoScreen({super.key, required this.videoId});
  final String videoId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final videoAsync = ref.watch(singleVideoProvider(videoId));

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: videoAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(color: AppColors.text)),
        error: (e, _) => Center(
          child: Text(
            e is DioException && e.response?.statusCode == 404 ? 'Video not found' : "Couldn't load this video",
            style: const TextStyle(color: AppColors.muted),
          ),
        ),
        data: (video) => Stack(
          children: [
            VideoSlide(
              video: video,
              isActive: true,
              onLikeTap: () {
                if (!ref.read(isLoggedInProvider)) return;
                ref.invalidate(singleVideoProvider(videoId));
              },
              onCommentTap: () => showCommentsSheet(context, videoId: video.id),
            ),
            SafeArea(
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
