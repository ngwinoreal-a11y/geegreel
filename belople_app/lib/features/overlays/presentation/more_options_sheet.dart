import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_typography.dart';
import '../../feed/data/feed_repository.dart';
import '../../feed/data/video_model.dart';
import '../../wallet/presentation/gift_sheet.dart';

/// Ports design-3.css section H (the "•••" sheet) for the actions that have
/// real backend support today per that file's own audit: Report, Block,
/// Repost. "Not interested" and message reactions are explicitly called out
/// there as not backed by any endpoint yet — omitted rather than wired to
/// nothing.
Future<void> showMoreOptionsSheet(
  BuildContext context,
  WidgetRef ref, {
  required VideoModel video,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.sheetBg,
    shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheetTop),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          _OptionRow(
            icon: Icons.card_giftcard,
            label: 'Send a gift',
            onTap: () {
              Navigator.of(sheetContext).pop();
              showGiftSheet(context, videoId: video.id);
            },
          ),
          _OptionRow(
            icon: Icons.repeat_rounded,
            label: 'Repost',
            onTap: () async {
              Navigator.of(sheetContext).pop();
              try {
                await ref.read(feedRepositoryProvider).repost(video.id);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Reposted to your profile')),
                  );
                }
              } on DioException catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(e.response?.statusCode == 409
                        ? 'You already reposted this'
                        : "Couldn't repost — check your connection"),
                  ));
                }
              }
            },
          ),
          _OptionRow(
            icon: Icons.person_off_outlined,
            label: 'Block @${video.user.username}',
            danger: true,
            onTap: () async {
              Navigator.of(sheetContext).pop();
              try {
                await ref.read(feedRepositoryProvider).setBlocked(video.user.id, true);
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('Blocked @${video.user.username}')));
                }
              } catch (_) {}
            },
          ),
          _OptionRow(
            icon: Icons.flag_outlined,
            label: 'Report',
            danger: true,
            onTap: () {
              Navigator.of(sheetContext).pop();
              _showReportSheet(context, ref, video);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

void _showReportSheet(BuildContext context, WidgetRef ref, VideoModel video) {
  const reasons = ['Spam', 'Nudity or sexual content', 'Violence', 'Harassment', 'Other'];
  showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.sheetBg,
    shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheetTop),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Report this video', style: AppTypography.sans(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.sheetInk)),
          ),
          for (final reason in reasons)
            _OptionRow(
              icon: Icons.chevron_right,
              label: reason,
              onTap: () async {
                Navigator.of(sheetContext).pop();
                try {
                  await ref.read(feedRepositoryProvider).reportVideo(video.id, reason);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Report submitted — thank you')));
                  }
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Couldn't submit report — check your connection")));
                  }
                }
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.icon, required this.label, required this.onTap, this.danger = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : AppColors.sheetInk;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: AppTypography.sans(fontSize: 15, color: color)),
      onTap: onTap,
    );
  }
}
