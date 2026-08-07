import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_typography.dart';
import '../data/sound_repository.dart';

/// Search-and-pick a shareable sound to attach to a video in the composer.
/// Backed by GET /api/sounds/search. Returns the chosen sound, or null if
/// dismissed.
Future<SoundModel?> showSoundPickerSheet(BuildContext context) {
  return showModalBottomSheet<SoundModel>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheetTop),
    builder: (_) => const _SoundPickerSheet(),
  );
}

class _SoundPickerSheet extends ConsumerStatefulWidget {
  const _SoundPickerSheet();

  @override
  ConsumerState<_SoundPickerSheet> createState() => _SoundPickerSheetState();
}

class _SoundPickerSheetState extends ConsumerState<_SoundPickerSheet> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<SoundModel>? _results;
  bool _loading = false;

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _run(value));
  }

  Future<void> _run(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _results = null);
      return;
    }
    setState(() => _loading = true);
    try {
      final results = await ref.read(soundRepositoryProvider).search(query);
      if (mounted) setState(() { _results = results; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _results = const []; _loading = false; });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        builder: (context, scrollController) => Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: TextField(
                controller: _controller,
                autofocus: true,
                onChanged: _onChanged,
                style: AppTypography.sans(fontSize: 14),
                decoration: const InputDecoration(hintText: 'Search sounds or creators'),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: AppColors.text))
                  : results == null
                      ? Center(
                          child: Text('Search for a sound to add',
                              style: AppTypography.sans(color: AppColors.muted)))
                      : results.isEmpty
                          ? Center(
                              child: Text('No sounds found',
                                  style: AppTypography.sans(color: AppColors.muted)))
                          : ListView.builder(
                              controller: scrollController,
                              itemCount: results.length,
                              itemBuilder: (context, i) {
                                final sound = results[i];
                                return ListTile(
                                  leading: const Icon(Icons.music_note, color: AppColors.accent),
                                  title: Text(sound.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppTypography.sans(fontWeight: FontWeight.w600)),
                                  subtitle: Text(
                                    '${sound.author ?? 'Unknown'} · ${sound.uses} videos',
                                    style: AppTypography.sans(fontSize: 12, color: AppColors.muted),
                                  ),
                                  onTap: () => Navigator.of(context).pop(sound),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}
