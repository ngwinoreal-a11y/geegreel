import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../auth/application/auth_controller.dart';
import '../../camera/data/capture_result.dart';
import '../data/sound_repository.dart';

/// Ports design-5.css section E (sound page): cover, title/author/use-count, a
/// grid of videos using it, and "Use this sound" — which opens the composer
/// with this sound attached (the video published there is tagged with it).
class SoundScreen extends ConsumerStatefulWidget {
  const SoundScreen({super.key, required this.soundId});
  final String soundId;

  @override
  ConsumerState<SoundScreen> createState() => _SoundScreenState();
}

class _SoundScreenState extends ConsumerState<SoundScreen> {
  AudioPlayer? _player;
  bool _playing = false;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  /// You could arrive on a sound's own page and still have no way to hear it —
  /// the one thing the page is about. Tapping the cover plays it.
  Future<void> _togglePlay(SoundModel sound) async {
    final url = sound.audioUrl;
    if (url == null) return;
    if (_playing) {
      await _player?.stop();
      if (mounted) setState(() => _playing = false);
      return;
    }
    setState(() => _playing = true);
    try {
      final p = _player ??= AudioPlayer();
      await p.setUrl(mediaUrl(url));
      await p.setLoopMode(LoopMode.one);
      await p.play();
    } catch (_) {
      if (mounted) setState(() => _playing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final soundAsync = ref.watch(soundProvider(widget.soundId));

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Sound')),
      body: soundAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(color: AppColors.text)),
        error: (e, _) => Center(
          child: Text("Couldn't load this sound", style: AppTypography.sans(color: AppColors.muted)),
        ),
        data: (detail) {
          final sound = detail.sound;
          // Every sound is titled "Original sound - <username>" because nothing
          // asks the poster for a name, so the source video's caption is the
          // only thing that identifies one. The stock title drops to the line
          // below rather than being the headline.
          // …but only when the caption is actually words. A caption of pure
          // emoji — which people write constantly — became a three-line wall
          // of hearts at headline size and told you nothing about the sound.
          final caption = sound.sourceCaption;
          final usable = caption != null && RegExp(r'[A-Za-z0-9]').hasMatch(caption);
          final title = usable ? caption : sound.title;

          // The author already has its own line under the title; repeating it
          // here made the same name appear twice, two lines apart.
          final facts = <String>[
            '${sound.uses} ${sound.uses == 1 ? 'video' : 'videos'}',
            if (sound.durationLabel != null) sound.durationLabel!,
          ];

          return Stack(
            children: [
              CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.pageHorizontal, AppSpacing.pageHorizontal, AppSpacing.pageHorizontal, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // The source video's first frame as cover art, with the
                      // play control on it. It was an empty grey square with a
                      // note glyph — the same placeholder for every sound in
                      // the app, telling you nothing.
                      GestureDetector(
                        onTap: () => _togglePlay(sound),
                        // Round, the way a record label is. A square read as a
                        // video thumbnail — which is literally what it is —
                        // and the page then looked like a video's page rather
                        // than a sound's.
                        child: ClipOval(
                          child: SizedBox(
                            width: 92,
                            height: 92,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (sound.coverUrl != null)
                                  CachedNetworkImage(imageUrl: mediaUrl(sound.coverUrl!), fit: BoxFit.cover)
                                else
                                  const DecoratedBox(
                                    decoration: BoxDecoration(color: AppColors.raised),
                                    child: Icon(Icons.music_note, color: AppColors.muted, size: 32),
                                  ),
                                DecoratedBox(
                                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.34)),
                                  child: Icon(
                                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                    color: Colors.white,
                                    size: 40,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // The name of the thing the page is about, at the
                            // size that says so. It was 17px — smaller than the
                            // button underneath it.
                            Text(title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.display(
                                    fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.text)),
                            if (sound.author != null && sound.author!.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(sound.author!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.sans(fontSize: 16, color: AppColors.muted)),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Length and reach on their own line, the way a track's facts sit
              // under its name everywhere else.
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.pageHorizontal, 0, AppSpacing.pageHorizontal, 16),
                  child: Row(children: [
                    Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        size: 22, color: AppColors.text),
                    const SizedBox(width: 6),
                    Text(facts.join('  ·  '),
                        style: AppTypography.sans(fontSize: 14.5, color: AppColors.muted)),
                  ]),
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
                        // ClipRect + expand, because a bare Image.network in a
                        // DecoratedBox took its own size and spilled out of the
                        // cell — one thumbnail came out several times taller
                        // than its neighbours and ran over the row below it.
                        child: ClipRect(
                          child: SizedBox.expand(
                            child: video.thumbUrl != null
                                ? CachedNetworkImage(
                                    imageUrl: mediaUrl(video.thumbUrl!),
                                    fit: BoxFit.cover,
                                    placeholder: (_, _) => const ColoredBox(color: AppColors.raised),
                                    errorWidget: (_, _, _) => const ColoredBox(color: AppColors.raised),
                                  )
                                : const ColoredBox(color: AppColors.raised),
                          ),
                        ),
                      );
                    },
                    childCount: detail.videos.length,
                  ),
                ),
              ),
              // Room for the floating button so the last row of thumbnails
              // isn't sitting under it.
              const SliverToBoxAdapter(child: SizedBox(height: 96)),
            ],
              ),

              // The action floats over the grid instead of taking a full-width
              // amber row at the top. As a slab it was the biggest thing on the
              // page and pushed the videos — the reason you came — below the
              // fold; down here it is always within reach and never in the way.
              Positioned(
                left: 0, right: 0, bottom: 22,
                child: Center(
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      if (!ref.read(isLoggedInProvider)) {
                        context.push('/login');
                        return;
                      }
                      // Record with the camera first, then land in the composer
                      // with this sound already attached. The camera is told
                      // which sound too, so it can name it and play it while
                      // you record.
                      final result = await context.push<CaptureResult>('/camera?sound=${widget.soundId}');
                      if (!context.mounted || result == null) return;
                      if (result.kind == CaptureKind.video) {
                        context.push('/compose?sound=${widget.soundId}', extra: {
                          'videoPath': result.path,
                          'filterIndex': result.filterIndex,
                        });
                      } else {
                        context.push('/compose?sound=${widget.soundId}');
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: AppColors.onAccent,
                      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                      textStyle: AppTypography.sans(fontSize: 16.5, fontWeight: FontWeight.w800),
                      elevation: 8,
                      // The app's button theme stretches every ElevatedButton
                      // to the full width, which turned this floating pill back
                      // into the amber slab it was meant to replace. Zero
                      // minimum, and it hugs its label.
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.videocam, size: 20),
                    label: const Text('Use this sound'),
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
