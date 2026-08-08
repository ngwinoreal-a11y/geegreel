import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../auth/application/auth_controller.dart';
import '../../chat/data/chat_repository.dart';
import '../../chat/data/message_model.dart';
import '../../feed/data/feed_repository.dart';
import '../../feed/data/video_model.dart';
import '../../wallet/presentation/gift_sheet.dart';

/// Ports the video "•••" sheet from the reference: quick actions (Save video /
/// Gift / Delete-or-Report), a Share-with row (Copy link / WhatsApp), Repost,
/// and a list of people you can send the video to as a DM.
Future<void> showMoreOptionsSheet(BuildContext context, WidgetRef ref, {required VideoModel video}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.sheetBg,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheetTop),
    builder: (_) => _MoreSheet(video: video),
  );
}

class _MoreSheet extends ConsumerStatefulWidget {
  const _MoreSheet({required this.video});
  final VideoModel video;

  @override
  ConsumerState<_MoreSheet> createState() => _MoreSheetState();
}

class _MoreSheetState extends ConsumerState<_MoreSheet> {
  List<ThreadPreview>? _people;

  @override
  void initState() {
    super.initState();
    _loadPeople();
  }

  Future<void> _loadPeople() async {
    try {
      final threads = await ref.read(chatRepositoryProvider).fetchInbox();
      if (mounted) setState(() => _people = threads.where((t) => !t.isPendingRequestToMe).toList());
    } catch (_) {
      if (mounted) setState(() => _people = const []);
    }
  }

  VideoModel get video => widget.video;

  Future<void> _shareUrl() async {
    try {
      return await ref.read(feedRepositoryProvider).share(video.id).then((url) async {
        await Clipboard.setData(ClipboardData(text: url));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
        }
      });
    } catch (_) {}
  }

  Future<String> _link() async => ref.read(feedRepositoryProvider).share(video.id);

  Future<void> _delete() async {
    Navigator.of(context).pop();
    try {
      await ref.read(feedRepositoryProvider).deleteVideo(video.id);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Video deleted')));
    } catch (_) {}
  }

  void _report() {
    // Keep the more-sheet mounted so its context stays valid; the report
    // sheet stacks on top and pops back to it.
    _showReportSheet(context, ref, video);
  }

  Future<void> _repost() async {
    Navigator.of(context).pop();
    try {
      await ref.read(feedRepositoryProvider).repost(video.id);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reposted to your profile')));
    } on DioException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.response?.statusCode == 409 ? 'You already reposted this' : "Couldn't repost")));
      }
    }
  }

  Future<void> _sendTo(ThreadPreview t) async {
    try {
      await ref.read(chatRepositoryProvider).sendVideo(recipientId: t.user.id, videoId: video.id);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sent to ${t.user.displayName}')));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authControllerProvider).valueOrNull;
    final isOwn = me != null && me.id == video.user.id;

    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.62,
        maxChildSize: 0.92,
        builder: (context, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(
                children: [
                  Expanded(child: Text('More', style: AppTypography.sans(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.sheetInk))),
                  IconButton(icon: const Icon(Icons.close, color: AppColors.sheetInk), onPressed: () => Navigator.of(context).pop()),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.sheetLine),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  // Quick actions row.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _QuickAction(
                          icon: Icons.download_outlined,
                          label: 'Save video',
                          onTap: () async {
                            final url = mediaUrl(video.videoUrl);
                            launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                          },
                        ),
                        _QuickAction(
                          icon: Icons.card_giftcard,
                          label: 'Gift',
                          onTap: () {
                            Navigator.of(context).pop();
                            showGiftSheet(context, videoId: video.id);
                          },
                        ),
                        if (isOwn)
                          _QuickAction(icon: Icons.delete_outline, label: 'Delete', danger: true, onTap: _delete)
                        else
                          _QuickAction(icon: Icons.flag_outlined, label: 'Report', danger: true, onTap: _report),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: AppColors.sheetLine),
                  // Share with.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                    child: Row(
                      children: [
                        Expanded(child: Text('Share with', style: AppTypography.sans(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.sheetInk))),
                        _ShareCircle(
                          color: const Color(0xFF25D366),
                          icon: Icons.chat,
                          onTap: () async {
                            final url = await _link();
                            launchUrl(Uri.parse('https://wa.me/?text=${Uri.encodeComponent(url)}'), mode: LaunchMode.externalApplication);
                          },
                        ),
                        const SizedBox(width: 10),
                        _ShareCircle(color: AppColors.sheetFill, icon: Icons.link, iconColor: AppColors.sheetInk, onTap: _shareUrl),
                      ],
                    ),
                  ),
                  // Repost.
                  ListTile(
                    leading: Container(
                      width: 40, height: 40,
                      decoration: const BoxDecoration(color: AppColors.repostGold, shape: BoxShape.circle),
                      child: const Icon(Icons.repeat_rounded, color: AppColors.onChrome, size: 22),
                    ),
                    title: Text('Repost', style: AppTypography.sans(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.sheetInk)),
                    trailing: const Icon(Icons.chevron_right, color: AppColors.sheetMuted),
                    onTap: _repost,
                  ),
                  const Divider(height: 1, color: AppColors.sheetLine),
                  // People to send to.
                  if (_people == null)
                    const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
                  else
                    for (final t in _people!)
                      ListTile(
                        leading: AppAvatar(
                          size: 40,
                          imageUrl: t.user.avatarUrl != null ? mediaUrl(t.user.avatarUrl!) : null,
                          displayName: t.user.displayName,
                        ),
                        title: Text(t.user.displayName, style: AppTypography.sans(fontSize: 15, color: AppColors.sheetInk)),
                        trailing: OutlinedButton(
                          onPressed: () => _sendTo(t),
                          style: OutlinedButton.styleFrom(foregroundColor: AppColors.sheetInk, side: const BorderSide(color: AppColors.sheetLine)),
                          child: const Text('Send'),
                        ),
                      ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.onTap, this.danger = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : AppColors.sheetInk;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52, height: 52,
            decoration: const BoxDecoration(color: AppColors.sheetFill, shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(height: 6),
          Text(label, style: AppTypography.sans(fontSize: 12, color: color)),
        ],
      ),
    );
  }
}

class _ShareCircle extends StatelessWidget {
  const _ShareCircle({required this.color, required this.icon, required this.onTap, this.iconColor = Colors.white});
  final Color color;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44, height: 44,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: iconColor, size: 22),
      ),
    );
  }
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
            ListTile(
              title: Text(reason, style: AppTypography.sans(fontSize: 15, color: AppColors.sheetInk)),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                try {
                  await ref.read(feedRepositoryProvider).reportVideo(video.id, reason);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report submitted — thank you')));
                  }
                } catch (_) {}
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
