import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_typography.dart';
import '../../feed/data/feed_repository.dart';
import '../../../core/widgets/top_toast.dart';

/// The "posted!" confirmation shown after a video upload completes: a small
/// looping preview of the video plus Share-to-people and Copy-link actions.
/// Auto-dismisses after 5 seconds if the user doesn't tap anything.
Future<void> showPostedSheet(
  BuildContext context,
  WidgetRef ref, {
  required String videoId,
  VideoPlayerController? previewController,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheetTop),
    builder: (_) => _PostedSheet(videoId: videoId, preview: previewController),
  );
}

class _PostedSheet extends ConsumerStatefulWidget {
  const _PostedSheet({required this.videoId, this.preview});
  final String videoId;
  final VideoPlayerController? preview;

  @override
  ConsumerState<_PostedSheet> createState() => _PostedSheetState();
}

class _PostedSheetState extends ConsumerState<_PostedSheet> {
  Timer? _autoClose;

  @override
  void initState() {
    super.initState();
    // Stays for 5s, then gets out of the way on its own.
    _autoClose = Timer(const Duration(seconds: 5), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _autoClose?.cancel();
    super.dispose();
  }

  Future<String> _link() => ref.read(feedRepositoryProvider).share(widget.videoId);

  Future<void> _copyLink() async {
    _autoClose?.cancel();
    try {
      final url = await _link();
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) {
        showTopToast(context, 'Link copied');
      }
    } catch (_) {}
  }

  Future<void> _shareToPeople() async {
    _autoClose?.cancel();
    try {
      final url = await _link();
      await Share.share(url, subject: 'Belople video');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle, color: AppColors.online, size: 22),
                const SizedBox(width: 8),
                Text('Posted!', style: AppTypography.display(fontSize: 18)),
                const Spacer(),
                IconButton(icon: const Icon(Icons.close, color: AppColors.muted), onPressed: () => Navigator.of(context).maybePop()),
              ],
            ),
            const SizedBox(height: 8),
            if (preview != null && preview.value.isInitialized)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: 200,
                  child: AspectRatio(
                    aspectRatio: preview.value.aspectRatio,
                    child: VideoPlayer(preview),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _shareToPeople,
                    icon: const Icon(Icons.ios_share, size: 18),
                    label: const Text('Share'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _copyLink,
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('Copy link'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
