import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/country_picker.dart';
import '../../../core/widgets/top_toast.dart';
import '../../auth/data/signup_options.dart';
import '../../feed/data/feed_repository.dart';
import '../../feed/data/video_model.dart';

/// Edits a video that's already posted: who can see it, its category, and the
/// country it's aimed at. Deleting was previously the only thing you could do
/// to a video already up, so fixing an audience meant losing the video's likes,
/// comments and watch history with it.
///
/// Returns true if something was saved, so the caller can refresh.
Future<bool?> showEditVideoSheet(BuildContext context, VideoModel video) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheetTop),
    builder: (_) => _EditVideoSheet(video: video),
  );
}

class _EditVideoSheet extends ConsumerStatefulWidget {
  const _EditVideoSheet({required this.video});
  final VideoModel video;

  @override
  ConsumerState<_EditVideoSheet> createState() => _EditVideoSheetState();
}

class _EditVideoSheetState extends ConsumerState<_EditVideoSheet> {
  late String _visibility = widget.video.visibility;
  late String? _category = widget.video.category;
  late String? _country =
      widget.video.countries.isNotEmpty ? widget.video.countries.first : null;
  bool _saving = false;

  Future<void> _pickCountry() async {
    final picked = await showCountryPicker(context, current: _country);
    if (picked == null || !mounted) return;
    setState(() => _country = picked == kEverywhere ? null : picked);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(feedRepositoryProvider).editVideo(
            widget.video.id,
            visibility: _visibility,
            category: _category,
            // Clearing is a real choice, not the absence of one.
            clearCategory: _category == null,
            country: _country,
            clearCountry: _country == null,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      showTopToast(context, 'Saved');
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      showTopToast(context, "Couldn't save — check your connection");
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('Edit video',
                      style: AppTypography.sans(
                          fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.text)),
                ),
                if (_saving)
                  const Padding(
                    padding: EdgeInsets.only(right: 14),
                    child: SizedBox(
                        height: 18, width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent)),
                  )
                else
                  TextButton(
                    onPressed: _save,
                    child: Text('Save',
                        style: AppTypography.sans(
                            fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.accent)),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text('WHO CAN SEE THIS', style: AppTypography.sectionLabel),
                const SizedBox(height: 8),
                for (final option in const [
                  ('public', Icons.public, 'Everyone', 'Anyone on Belople can watch'),
                  ('followers', Icons.group, 'Followers', 'Only people who follow you'),
                  ('private', Icons.lock_outline, 'Private', 'Only you'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _visibility = option.$1),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                        decoration: BoxDecoration(
                          color: AppColors.raised,
                          borderRadius: BorderRadius.circular(AppRadii.md),
                          border: Border.all(
                              color: _visibility == option.$1 ? AppColors.accent : AppColors.border),
                        ),
                        child: Row(
                          children: [
                            Icon(option.$2,
                                color: _visibility == option.$1 ? AppColors.accent : AppColors.muted),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(option.$3,
                                      style: AppTypography.sans(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.text)),
                                  Text(option.$4,
                                      style: AppTypography.sans(
                                          fontSize: 13, color: AppColors.muted)),
                                ],
                              ),
                            ),
                            if (_visibility == option.$1)
                              const Icon(Icons.check_circle, color: AppColors.accent, size: 22),
                          ],
                        ),
                      ),
                    ),
                  ),

                const SizedBox(height: 20),
                Text('CATEGORY', style: AppTypography.sectionLabel),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in kInterests)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _category = _category == c ? null : c),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: _category == c ? AppColors.accentSoft : AppColors.raised,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: _category == c ? AppColors.accent : AppColors.border),
                          ),
                          child: Text(c,
                              style: AppTypography.sans(
                                fontSize: 15,
                                fontWeight: _category == c ? FontWeight.w700 : FontWeight.w500,
                                color: _category == c ? AppColors.accent : AppColors.text,
                              )),
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: 20),
                Text('COUNTRY', style: AppTypography.sectionLabel),
                const SizedBox(height: 10),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _pickCountry,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(
                      color: AppColors.raised,
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      border: Border.all(
                          color: _country == null ? AppColors.border : AppColors.accent),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.public, size: 20, color: AppColors.muted),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(_country ?? 'Everywhere',
                              style: AppTypography.sans(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: _country == null ? AppColors.muted : AppColors.text)),
                        ),
                        const Icon(Icons.chevron_right, color: AppColors.muted),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
