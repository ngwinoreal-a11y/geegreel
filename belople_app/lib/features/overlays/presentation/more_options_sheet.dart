import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/top_toast.dart';
import '../../auth/application/auth_controller.dart';
import '../../chat/data/chat_repository.dart';
import '../../chat/data/message_model.dart';
import '../../feed/application/playback_speed.dart';
import '../../feed/data/feed_repository.dart';
import '../../feed/data/video_model.dart';
import '../../profile/data/profile_repository.dart';
import '../data/video_watermark_service.dart';
import 'edit_video_sheet.dart';

/// Ports the video "•••" sheet from the reference: quick actions (Save video /
/// Gift / Delete-or-Report), a Share-with row (Copy link / WhatsApp), Repost,
/// and a list of people you can send the video to as a DM.
Future<void> showMoreOptionsSheet(BuildContext context, WidgetRef ref,
    {required VideoModel video, VoidCallback? onDeleted}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.sheetBg,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheetTop),
    builder: (_) => _MoreSheet(video: video, onDeleted: onDeleted),
  );
}

class _MoreSheet extends ConsumerStatefulWidget {
  const _MoreSheet({required this.video, this.onDeleted});
  final VideoModel video;
  /// Called after a successful delete so the caller can drop the video from
  /// its list (feed) or leave the screen (single-video) — without it the video
  /// would vanish server-side but stay on screen, looking like nothing happened.
  final VoidCallback? onDeleted;

  @override
  ConsumerState<_MoreSheet> createState() => _MoreSheetState();
}

class _MoreSheetState extends ConsumerState<_MoreSheet> {
  List<ThreadPreview>? _people;
  bool _downloading = false;
  bool _processing = false;
  double _downloadProgress = 0;
  double _processProgress = 0;

  @override
  void initState() {
    super.initState();
    _loadPeople();
  }

  /// Show the cached inbox instantly (feels offline-fast), then refresh.
  Future<void> _loadPeople() async {
    final cached = ref.read(chatRepositoryProvider).readCachedInbox();
    if (cached != null) {
      _people = cached.where((t) => !t.isPendingRequestToMe).toList();
    }
    try {
      final threads = await ref.read(chatRepositoryProvider).fetchInbox();
      if (mounted) setState(() => _people = threads.where((t) => !t.isPendingRequestToMe).toList());
    } catch (_) {
      if (mounted && _people == null) setState(() => _people = const []);
    }
  }

  VideoModel get video => widget.video;

  /// Downloads the video in-app with a progress bar, then saves it to the
  /// phone's gallery — no browser hop.
  Future<void> _saveVideo() async {
    if (_downloading) return;
    setState(() { _downloading = true; _downloadProgress = 0; });
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/belople_${video.id}.mp4';
      await ref.read(dioProvider).download(
        mediaUrl(video.videoUrl),
        path,
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) setState(() => _downloadProgress = received / total);
        },
      );
      // Burn in the moving Belople watermark + branded outro — only on the
      // saved file; in-app playback stays clean. On any failure this returns
      // the original path, so the save still happens (just unbranded).
      if (mounted) setState(() { _processing = true; _processProgress = 0; });
      final branded = await VideoWatermarkService.brandForDownload(
        sourcePath: path,
        username: video.user.username,
        width: video.width,
        height: video.height,
        onProgress: (p) {
          if (mounted) setState(() => _processProgress = p);
        },
      );
      await Gal.putVideo(branded, album: 'Belople');
      if (mounted) {
        showTopToast(context, 'Saved to your gallery');
      }
    } catch (_) {
      if (mounted) {
        showTopToast(context, "Couldn't save the video");
      }
    } finally {
      if (mounted) setState(() { _downloading = false; _processing = false; });
    }
  }

  /// Cycles the playback speed (0.5x → 1x → 1.5x → 2x → …) applied to the
  /// playing video via [playbackSpeedProvider].
  void _cycleSpeed() {
    final current = ref.read(playbackSpeedProvider);
    final i = kPlaybackSpeeds.indexOf(current);
    final next = kPlaybackSpeeds[(i + 1) % kPlaybackSpeeds.length];
    ref.read(playbackSpeedProvider.notifier).state = next;
  }

  /// Native share sheet — shows whatever apps are installed (WhatsApp,
  /// Facebook, Messenger, …) with the video's link.
  Future<void> _shareToApps() async {
    try {
      final url = await _link();
      await Share.share(url, subject: 'Belople video');
    } catch (_) {}
  }

  static String _fmtSpeed(double s) => s == s.truncateToDouble() ? '${s.toInt()}x' : '${s}x';

  Future<void> _shareUrl() async {
    try {
      return await ref.read(feedRepositoryProvider).share(video.id).then((url) async {
        await Clipboard.setData(ClipboardData(text: url));
        if (mounted) {
          showTopToast(context, 'Link copied');
        }
      });
    } catch (_) {}
  }

  Future<String> _link() async => ref.read(feedRepositoryProvider).share(video.id);

  Future<void> _delete() async {
    try {
      await ref.read(feedRepositoryProvider).deleteVideo(video.id);
      widget.onDeleted?.call(); // drop it from the feed in place
      // …and refresh the owner's profile grid so it's gone there too.
      ref.invalidate(profileProvider(video.user.username));
      if (mounted) {
        // Toast into the ROOT overlay first (survives the sheet closing), then pop.
        showTopToast(context, 'Video deleted');
        Navigator.of(context).pop();
      }
    } catch (e) {
      // Surface the backend's actual reason (e.g. "Other people's videos use
      // this video's sound…") instead of a blank generic failure.
      if (mounted) showTopToast(context, apiErrorMessage(e, "Couldn't delete — try again"));
    }
  }

  void _report() {
    // Keep the more-sheet mounted so its context stays valid; the report
    // sheet stacks on top and pops back to it.
    _showReportSheet(context, ref, video);
  }

  Future<void> _repost() async {
    try {
      await ref.read(feedRepositoryProvider).repost(video.id);
      if (mounted) {
        showTopToast(context, 'Reposted to your profile');
        Navigator.of(context).pop();
      }
    } on DioException catch (e) {
      if (mounted) {
        showTopToast(context, e.response?.statusCode == 409 ? 'You already reposted this' : "Couldn't repost");
        Navigator.of(context).pop();
      }
    }
  }

  /// Who this video has already been sent to in this sheet, and who is
  /// in-flight — the button had no state at all, so tapping Send looked
  /// identical to not tapping it.
  final Set<String> _sentTo = {};
  final Set<String> _sendingTo = {};

  Future<void> _edit() async {
    // Close this sheet first so the editor isn't stacked on top of it — backing
    // out of the editor should land on the video, not back here.
    Navigator.of(context).pop();
    await showEditVideoSheet(context, video);
  }

  Future<void> _sendTo(ThreadPreview t) async {
    final id = t.user.id;
    // A blank id would key every row's state to the same entry — one tap would
    // spin all of them — and the send itself has no recipient. Say so instead.
    if (id.isEmpty) {
      showTopToast(context, "Couldn't send — reopen Messages and try again");
      return;
    }
    if (_sendingTo.contains(id) || _sentTo.contains(id)) return;
    setState(() => _sendingTo.add(id));
    try {
      await ref.read(chatRepositoryProvider).sendVideo(recipientId: id, videoId: video.id);
      if (!mounted) return;
      setState(() { _sendingTo.remove(id); _sentTo.add(id); });
      showTopToast(context, 'Sent to ${t.user.displayName}');
    } catch (_) {
      // Was swallowed silently: a failed send and a successful one looked the
      // same, which is why this button felt dead.
      if (!mounted) return;
      setState(() => _sendingTo.remove(id));
      showTopToast(context, "Couldn't send — check your connection");
    }
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
                  // Quick actions row: Save (with progress) / Speed / Delete-Report.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _QuickAction(
                          icon: Icons.download_outlined,
                          label: _processing
                              ? (_processProgress > 0
                                  ? 'Finishing ${(_processProgress * 100).toStringAsFixed(0)}%'
                                  : 'Finishing…')
                              : _downloading
                                  ? '${(_downloadProgress * 100).toStringAsFixed(0)}%'
                                  : 'Save video',
                          busy: _downloading || _processing,
                          // Show real encode progress when we have it, else an
                          // indeterminate spinner (0).
                          progress: _processing ? _processProgress : _downloadProgress,
                          onTap: _saveVideo,
                        ),
                        _QuickAction(
                          icon: Icons.speed,
                          label: '${_fmtSpeed(ref.watch(playbackSpeedProvider))} Speed',
                          onTap: _cycleSpeed,
                        ),
                        // Edit sits before Delete on purpose: changing who can
                        // see a video was only possible by deleting it and
                        // re-uploading, which threw away its likes, comments
                        // and watch history.
                        if (isOwn)
                          _QuickAction(icon: Icons.edit_outlined, label: 'Edit', onTap: _edit),
                        if (isOwn)
                          _QuickAction(icon: Icons.delete_outline, label: 'Delete', danger: true, onTap: _delete)
                        else
                          _QuickAction(icon: Icons.flag_outlined, label: 'Report', danger: true, onTap: _report),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: AppColors.sheetLine),
                  // Share with — native sheet (installed apps) + copy link.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                    child: Row(
                      children: [
                        Expanded(child: Text('Share with', style: AppTypography.sans(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.sheetInk))),
                        _ShareCircle(color: const Color(0xFF25D366), icon: Icons.ios_share, onTap: _shareToApps),
                        const SizedBox(width: 10),
                        _ShareCircle(color: AppColors.sheetFill, icon: Icons.link, iconColor: AppColors.sheetInk, onTap: _shareUrl),
                      ],
                    ),
                  ),
                  // Repost — hidden on your own video (you can't repost yourself).
                  if (!isOwn) ...[
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
                  ],
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
                        trailing: Builder(builder: (_) {
                          final sent = _sentTo.contains(t.user.id);
                          final sending = _sendingTo.contains(t.user.id);
                          return OutlinedButton(
                            onPressed: sent || sending ? null : () => _sendTo(t),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: sent ? AppColors.online : AppColors.sheetInk,
                              side: BorderSide(color: sent ? AppColors.online : AppColors.sheetLine),
                              disabledForegroundColor: sent ? AppColors.online : AppColors.sheetMuted,
                            ),
                            child: sending
                                ? const SizedBox(
                                    height: 14, width: 14,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.sheetInk))
                                : Text(sent ? 'Sent' : 'Send'),
                          );
                        }),
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
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.busy = false,
    this.progress = 0,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  final bool busy;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : AppColors.sheetInk;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: busy ? null : onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52, height: 52,
            decoration: const BoxDecoration(color: AppColors.sheetFill, shape: BoxShape.circle),
            child: busy
                ? Center(
                    child: SizedBox(
                      width: 24, height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        value: progress > 0 ? progress : null,
                        color: AppColors.sheetInk,
                      ),
                    ),
                  )
                : Icon(icon, color: color, size: 24),
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

/// Asks the reporter to describe the problem in their own words. Returns null
/// if they back out, so choosing "Other" and then changing your mind doesn't
/// file an empty report.
Future<String?> _askReportReason(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.sheetBg,
      title: Text("What's wrong with this video?",
          style: AppTypography.sans(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.sheetInk)),
      // This dialog is WHITE (sheetBg), but the field inherited the app's dark
      // InputDecoration theme — a dark box with near-black ink in it, so
      // whatever the reporter typed was invisible, and the two actions were
      // white-on-white. Every colour here is stated rather than inherited.
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLines: 3,
        maxLength: 300,
        cursorColor: AppColors.sheetInk,
        style: AppTypography.sans(fontSize: 16, color: AppColors.sheetInk),
        decoration: InputDecoration(
          hintText: 'Tell us what happened',
          hintStyle: AppTypography.sans(fontSize: 16, color: AppColors.sheetMuted),
          filled: true,
          fillColor: AppColors.sheetFill,
          counterStyle: AppTypography.sans(fontSize: 11, color: AppColors.sheetMuted),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.sheetLine),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.sheetInk),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text('Cancel', style: AppTypography.sans(fontSize: 15, color: AppColors.sheetMuted)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: Text('Send report',
              style: AppTypography.sans(
                  fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.danger)),
        ),
      ],
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
            ListTile(
              title: Text(reason, style: AppTypography.sans(fontSize: 15, color: AppColors.sheetInk)),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                // "Other" means the listed reasons don't fit, so it has to
                // accept the one the reporter actually has — otherwise the
                // moderator receives the word "Other" and nothing else.
                String finalReason = reason;
                if (reason == 'Other' && context.mounted) {
                  final typed = await _askReportReason(context);
                  if (typed == null || typed.trim().isEmpty) return; // cancelled
                  finalReason = 'Other: ${typed.trim()}';
                }
                try {
                  await ref.read(feedRepositoryProvider).reportVideo(video.id, finalReason);
                  if (context.mounted) {
                    showTopToast(context, 'Report submitted — thank you');
                  }
                } catch (_) {
                  if (context.mounted) showTopToast(context, "Couldn't send the report");
                }
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
