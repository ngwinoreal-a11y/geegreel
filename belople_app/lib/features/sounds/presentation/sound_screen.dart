import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../auth/application/auth_controller.dart';
import '../data/sound_repository.dart';

/// Ports design-5.css section E (sound page): title/author/use-count, a grid
/// of videos using it, and "Use this sound" — which opens the composer with
/// this sound attached (the video published there is tagged with it).
class SoundScreen extends ConsumerWidget {
  const SoundScreen({super.key, required this.soundId});
  final String soundId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final soundAsync = ref.watch(soundProvider(soundId));

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Sound')),
      body: soundAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(color: AppColors.text)),
        error: (e, _) => Center(
          child: Text("Couldn't load this sound", style: AppTypography.sans(color: AppColors.muted)),
        ),
        data: (detail) {
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
                  child: Row(
                    children: [
                      Container(
                        width: 88,
                        height: 88,
                        decoration: BoxDecoration(color: AppColors.raised, borderRadius: BorderRadius.circular(10)),
                        child: const Icon(Icons.music_note, color: AppColors.muted, size: 32),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(detail.sound.title, style: AppTypography.display(fontSize: 17)),
                            if (detail.sound.author != null) ...[
                              const SizedBox(height: 4),
                              Text(detail.sound.author!, style: AppTypography.sans(fontSize: 13, color: AppColors.muted)),
                            ],
                            const SizedBox(height: 6),
                            Text('${detail.sound.uses} videos', style: AppTypography.mono(fontSize: 12, color: AppColors.muted)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.pageHorizontal, 0, AppSpacing.pageHorizontal, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        if (!ref.read(isLoggedInProvider)) {
                          context.push('/login');
                          return;
                        }
                        // Record with the camera first, then land in the
                        // composer with this sound already attached.
                        final result = await context.push<String>('/camera');
                        if (!context.mounted || result == null) return;
                        if (result.startsWith('video:')) {
                          context.push('/compose?sound=$soundId', extra: {'videoPath': result.substring(6)});
                        } else {
                          context.push('/compose?sound=$soundId');
                        }
                      },
                      icon: const Icon(Icons.videocam, size: 18),
                      label: const Text('Use this sound'),
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 3,
                    crossAxisSpacing: 3,
                    childAspectRatio: 9 / 14,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final video = detail.videos[index];
                      return GestureDetector(
                        onTap: () => context.push('/v/${video.id}'),
                        child: DecoratedBox(
                          decoration: const BoxDecoration(color: AppColors.raised),
                          child: video.thumbUrl != null
                              ? Image.network(mediaUrl(video.thumbUrl!), fit: BoxFit.cover)
                              : null,
                        ),
                      );
                    },
                    childCount: detail.videos.length,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
