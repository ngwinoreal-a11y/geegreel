import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../auth/application/auth_controller.dart';
import '../data/comment_model.dart';
import '../data/comment_repository.dart';

/// Plain text comments on a user ad — no reactions/replies (that's what the ad
/// backend supports). Separate from the video comments sheet so neither has to
/// carry the other's features.
Future<void> showAdCommentsSheet(BuildContext context, {required String adId}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.sheetBg,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (_) => _AdCommentsSheet(adId: adId),
  );
}

class _AdCommentsSheet extends ConsumerStatefulWidget {
  const _AdCommentsSheet({required this.adId});
  final String adId;

  @override
  ConsumerState<_AdCommentsSheet> createState() => _AdCommentsSheetState();
}

class _AdCommentsSheetState extends ConsumerState<_AdCommentsSheet> {
  final _controller = TextEditingController();
  List<CommentModel>? _comments;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final comments = await ref.read(commentRepositoryProvider).fetchAdComments(widget.adId);
      if (mounted) setState(() => _comments = comments);
    } catch (_) {
      if (mounted) setState(() => _comments = const []);
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    if (!ref.read(isLoggedInProvider)) return;
    setState(() => _sending = true);
    try {
      await ref.read(commentRepositoryProvider).postAdComment(widget.adId, text);
      _controller.clear();
      await _load();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final comments = _comments;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 12),
            Text('Comments', style: AppTypography.sans(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.sheetInk)),
            const Divider(height: 20, color: AppColors.sheetLine),
            Expanded(
              child: comments == null
                  ? const Center(child: CircularProgressIndicator())
                  : comments.isEmpty
                      ? Center(child: Text('No comments yet', style: AppTypography.sans(color: AppColors.onSheetMuted)))
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: comments.length,
                          itemBuilder: (context, i) => _CommentRow(comment: comments[i]),
                        ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        style: AppTypography.sans(color: AppColors.sheetInk),
                        decoration: InputDecoration(
                          hintText: 'Add a comment…',
                          filled: true,
                          fillColor: const Color(0xFFF0F0F2),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    IconButton(
                      icon: _sending
                          ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send, color: AppColors.accent),
                      onPressed: _send,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({required this.comment});
  final CommentModel comment;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAvatar(
            size: 34,
            imageUrl: comment.user.avatarUrl != null ? mediaUrl(comment.user.avatarUrl!) : null,
            displayName: comment.user.displayName,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(comment.user.displayName,
                    style: AppTypography.sans(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.onSheetMuted)),
                const SizedBox(height: 2),
                Text(comment.body, style: AppTypography.sans(fontSize: 14, color: AppColors.sheetInk)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
