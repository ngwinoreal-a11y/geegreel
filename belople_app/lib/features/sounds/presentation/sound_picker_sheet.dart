import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_typography.dart';
import '../data/sound_repository.dart';

/// Pick a sound to attach to a video in the composer. Backed by
/// GET /api/sounds/search. Returns the chosen sound, or null if dismissed.
Future<SoundModel?> showSoundPickerSheet(BuildContext context) {
  return showModalBottomSheet<SoundModel>(
    context: context,
    isScrollControlled: true,
    // White, like the app's other sheets and like every music picker people
    // already use. Cover art needs a light ground to read against — on the
    // dark surface this sheet used, thumbnails all bled into the background.
    backgroundColor: Colors.white,
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

  /// Plays whichever row's play button was last pressed. Choosing a sound you
  /// have never heard is a guess; this is the whole reason to have a picker
  /// rather than a list of names.
  AudioPlayer? _player;
  String? _previewingId;

  @override
  void initState() {
    super.initState();
    // Popular sounds up front. An empty box used to mean an empty sheet, so
    // you had to already know what you were looking for before it showed you
    // anything at all.
    _run('');
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _run(value));
  }

  Future<void> _run(String query) async {
    setState(() => _loading = true);
    try {
      final results = await ref.read(soundRepositoryProvider).search(query.trim());
      if (mounted) setState(() { _results = results; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _results = const []; _loading = false; });
    }
  }

  Future<void> _togglePreview(SoundModel sound) async {
    final url = sound.audioUrl;
    if (url == null) return;
    // Pressing the one that's already playing stops it.
    if (_previewingId == sound.id) {
      await _player?.stop();
      if (mounted) setState(() => _previewingId = null);
      return;
    }
    setState(() => _previewingId = sound.id);
    try {
      final p = _player ??= AudioPlayer();
      await p.setUrl(mediaUrl(url));
      await p.setLoopMode(LoopMode.one);
      await p.play();
    } catch (_) {
      if (mounted) setState(() => _previewingId = null);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    final searching = _controller.text.trim().isNotEmpty;

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
              decoration: BoxDecoration(color: AppColors.sheetLine, borderRadius: BorderRadius.circular(2)),
            ),
            // A white sheet inside a dark app: every colour on the field is
            // named, or it inherits the dark theme and the text disappears.
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              child: TextField(
                controller: _controller,
                onChanged: (v) { setState(() {}); _onChanged(v); },
                style: AppTypography.sans(fontSize: 15, color: AppColors.sheetInk),
                cursorColor: AppColors.sheetInk,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: AppColors.sheetFill,
                  hintText: 'Search sounds or creators',
                  hintStyle: AppTypography.sans(fontSize: 15, color: AppColors.sheetMuted),
                  prefixIcon: const Icon(Icons.search, size: 20, color: AppColors.sheetMuted),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            if (!searching && (results?.isNotEmpty ?? false))
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 2, 18, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('MOST USED',
                      style: AppTypography.sans(
                          fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.sheetMuted)),
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: AppColors.sheetInk))
                  : (results == null || results.isEmpty)
                      ? Center(
                          child: Text(
                              searching ? 'No sounds match that' : 'No sounds yet',
                              style: AppTypography.sans(color: AppColors.sheetMuted)))
                      : ListView.separated(
                          controller: scrollController,
                          padding: const EdgeInsets.only(bottom: 24),
                          itemCount: results.length,
                          separatorBuilder: (_, _) => const Padding(
                            padding: EdgeInsets.only(left: 76),
                            child: Divider(height: 1, thickness: 1, color: AppColors.sheetLine),
                          ),
                          itemBuilder: (context, i) => _SoundRow(
                            sound: results[i],
                            playing: _previewingId == results[i].id,
                            onPreview: () => _togglePreview(results[i]),
                            onPick: () => Navigator.of(context).pop(results[i]),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One sound: cover, name, and the line that tells them apart.
class _SoundRow extends StatelessWidget {
  const _SoundRow({
    required this.sound,
    required this.playing,
    required this.onPreview,
    required this.onPick,
  });
  final SoundModel sound;
  final bool playing;
  final VoidCallback onPreview;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    // Every sound is called "Original sound - <username>" — nothing asks the
    // poster for a title — so a search came back as four identical rows. The
    // source video's caption is what actually distinguishes them; it becomes
    // the name when there is one, and the stock title drops to the line below.
    final caption = sound.sourceCaption;
    final title = (caption != null && caption.isNotEmpty) ? caption : sound.title;

    final bits = <String>[
      if (sound.author != null && sound.author!.isNotEmpty) sound.author!,
      '${sound.uses} ${sound.uses == 1 ? 'video' : 'videos'}',
      if (sound.durationLabel != null) sound.durationLabel!,
    ];

    // Tapping the row LISTENS. It used to choose the sound and close the
    // sheet, so browsing was impossible: one stray tap and you were committed
    // to something you had never heard. Only Use commits.
    return InkWell(
      onTap: onPreview,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            GestureDetector(
              onTap: onPreview,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 50,
                  height: 50,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (sound.coverUrl != null)
                        CachedNetworkImage(imageUrl: mediaUrl(sound.coverUrl!), fit: BoxFit.cover)
                      else
                        Container(
                          color: AppColors.sheetFill,
                          child: const Icon(Icons.music_note, color: AppColors.sheetMuted, size: 22),
                        ),
                      DecoratedBox(
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.32)),
                        child: Icon(
                          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 26,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.sans(
                          fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.sheetInk)),
                  const SizedBox(height: 3),
                  Text(bits.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.sans(fontSize: 13, color: AppColors.sheetMuted)),
                ],
              ),
            ),
            // The only thing on the row that commits, so it is the only thing
            // wearing the brand colour — and big enough to be aimed at without
            // looking. Everything else here just plays.
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 6),
              child: ElevatedButton(
                onPressed: onPick,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.onAccent,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  textStyle: AppTypography.sans(fontSize: 16, fontWeight: FontWeight.w800),
                ),
                child: const Text('Use'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
