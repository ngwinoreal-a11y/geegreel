import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../sounds/data/sound_repository.dart';
import '../../sounds/presentation/sound_picker_sheet.dart';
import '../data/upload_repository.dart';
import 'posted_sheet.dart';

enum _ComposerMode { video, photo, text }

/// Ports index.html's uploadPage()/publicUploadPage()/textPostPage() as one
/// screen with a mode switch, matching the reference's single-state-machine
/// approach (see the plan). Live camera preview + in-app recording + the 9
/// filter presets are deferred (the plan's explicit highest-risk item) —
/// this covers the full real publish path (pick from camera roll or record
/// via the OS camera UI, caption, upload with progress, land in the feed)
/// end to end against the real backend.
class ComposerScreen extends ConsumerStatefulWidget {
  const ComposerScreen({super.key, this.soundId, this.videoPath, this.imagePath, this.initialMode});

  /// When arriving from a sound page's "Use this sound", the picked video is
  /// attached to this sound on publish. Locks the composer to video mode.
  final String? soundId;

  /// A video just recorded in the in-app camera, handed straight in so the
  /// composer opens already showing it (no re-pick needed).
  final String? videoPath;

  /// A photo captured/picked in the camera's Public mode.
  final String? imagePath;

  /// Which post type the camera chose: 'photo' or 'text' (else video).
  final String? initialMode;

  @override
  ConsumerState<ComposerScreen> createState() => _ComposerScreenState();
}

class _ComposerScreenState extends ConsumerState<ComposerScreen> {
  late _ComposerMode _mode = switch (widget.initialMode) {
    'photo' => _ComposerMode.photo,
    'text' => _ComposerMode.text,
    _ => _ComposerMode.video,
  };
  File? _videoFile;
  File? _imageFile;
  VideoPlayerController? _previewController;
  final _captionController = TextEditingController();
  bool _uploading = false;
  bool _soundShareable = false;
  SoundModel? _pickedSound;
  double _progress = 0;
  String? _error;

  final _picker = ImagePicker();

  /// A sound attached from a sound page locks the composer to that sound;
  /// otherwise the user can search-and-pick one here.
  bool get _usingSound => widget.soundId != null;

  /// The sound id actually sent on publish (page-attached wins over picked).
  String? get _effectiveSoundId => widget.soundId ?? _pickedSound?.id;

  @override
  void initState() {
    super.initState();
    // Media handed in from the in-app camera previews immediately.
    if (widget.videoPath != null) {
      _loadVideoPreview(File(widget.videoPath!));
    } else if (widget.imagePath != null) {
      _imageFile = File(widget.imagePath!);
    }
  }

  Future<void> _pickSound() async {
    final sound = await showSoundPickerSheet(context);
    if (sound != null) setState(() => _pickedSound = sound);
  }

  @override
  void dispose() {
    _previewController?.dispose();
    _captionController.dispose();
    super.dispose();
  }

  /// Opens the in-app camera (live preview + filters); falls back to nothing
  /// if the user backs out. Returns via the same preview path as gallery.
  Future<void> _recordInApp() async {
    final result = await context.push<String>('/camera');
    if (result == null) return;
    if (result.startsWith('video:')) {
      await _loadVideoPreview(File(result.substring(6)));
    } else if (result.startsWith('photo:') && mounted) {
      setState(() { _imageFile = File(result.substring(6)); _mode = _ComposerMode.photo; });
    }
  }

  Future<void> _pickVideo(ImageSource source) async {
    final picked = await _picker.pickVideo(source: source, maxDuration: const Duration(minutes: 1));
    if (picked == null) return;
    await _loadVideoPreview(File(picked.path));
  }

  Future<void> _loadVideoPreview(File file) async {
    _previewController?.dispose();
    final controller = VideoPlayerController.file(file);
    await controller.initialize();
    await controller.setLooping(true);
    controller.play();
    if (!mounted) return;
    setState(() {
      _videoFile = file;
      _previewController = controller;
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    final picked = await _picker.pickImage(source: source, imageQuality: 90);
    if (picked == null) return;
    setState(() => _imageFile = File(picked.path));
  }

  Future<void> _publish() async {
    if (_uploading) return;
    setState(() { _uploading = true; _error = null; _progress = 0; });
    try {
      final repo = ref.read(uploadRepositoryProvider);
      String? uploadedVideoId;
      if (_mode == _ComposerMode.video) {
        if (_videoFile == null) throw Exception('Pick or record a video first');
        uploadedVideoId = await repo.uploadVideo(
          file: _videoFile!,
          caption: _captionController.text.trim(),
          soundId: _effectiveSoundId,
          soundShareable: _soundShareable,
          onProgress: (sent, total) {
            if (total > 0 && mounted) setState(() => _progress = sent / total);
          },
        );
      } else {
        await repo.uploadPost(
          imageFile: _imageFile,
          content: _captionController.text.trim(),
          onProgress: (sent, total) {
            if (total > 0 && mounted) setState(() => _progress = sent / total);
          },
        );
      }
      if (!mounted) return;
      if (uploadedVideoId != null && uploadedVideoId.isNotEmpty) {
        await showPostedSheet(context, ref, videoId: uploadedVideoId, previewController: _previewController);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Posted!')));
      }
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) setState(() => _error = "Couldn't publish — check your connection and try again");
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  bool get _canPublish {
    if (_mode == _ComposerMode.video) return _videoFile != null;
    if (_mode == _ComposerMode.photo) return _imageFile != null || _captionController.text.trim().isNotEmpty;
    return _captionController.text.trim().isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('New post'),
        actions: [
          TextButton(
            onPressed: (_canPublish && !_uploading) ? _publish : null,
            child: _uploading
                ? Text('${(_progress * 100).toStringAsFixed(0)}%')
                : const Text('Post'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_usingSound)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadii.lg),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.music_note, color: AppColors.accent, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Using this sound',
                          style: AppTypography.sans(fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              )
            else ...[
              Row(
                children: [
                  _ModeChip(
                    label: 'Video',
                    selected: _mode == _ComposerMode.video,
                    onTap: () => setState(() => _mode = _ComposerMode.video),
                  ),
                  const SizedBox(width: 8),
                  _ModeChip(
                    label: 'Photo',
                    selected: _mode == _ComposerMode.photo,
                    onTap: () => setState(() => _mode = _ComposerMode.photo),
                  ),
                  const SizedBox(width: 8),
                  _ModeChip(
                    label: 'Text',
                    selected: _mode == _ComposerMode.text,
                    onTap: () => setState(() => _mode = _ComposerMode.text),
                  ),
                ],
              ),
              const SizedBox(height: 20),
            ],

            if (_mode == _ComposerMode.video) ...[
              if (_previewController != null && _previewController!.value.isInitialized)
                AspectRatio(
                  aspectRatio: _previewController!.value.aspectRatio,
                  child: VideoPlayer(_previewController!),
                )
              else
                _PickerBox(icon: Icons.videocam_outlined, label: 'No video selected'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _recordInApp,
                      icon: const Icon(Icons.videocam),
                      label: const Text('Record'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickVideo(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Gallery'),
                    ),
                  ),
                ],
              ),
              if (!_usingSound) ...[
                const SizedBox(height: 6),
                if (_pickedSound == null)
                  OutlinedButton.icon(
                    onPressed: _pickSound,
                    icon: const Icon(Icons.music_note, size: 18),
                    label: const Text('Add a sound'),
                  )
                else
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.music_note, color: AppColors.accent),
                    title: Text(_pickedSound!.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.sans(fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: _pickedSound!.author != null
                        ? Text(_pickedSound!.author!,
                            style: AppTypography.sans(fontSize: 12, color: AppColors.muted))
                        : null,
                    trailing: IconButton(
                      icon: const Icon(Icons.close, color: AppColors.muted),
                      onPressed: () => setState(() => _pickedSound = null),
                    ),
                  ),
              ],
              // A video's audio can't both use an existing sound and become a
              // new shareable one — offer the opt-in only when no sound is
              // attached.
              if (!_usingSound && _pickedSound == null && _videoFile != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _soundShareable,
                  onChanged: (v) => setState(() => _soundShareable = v),
                  title: Text('Let others use this sound',
                      style: AppTypography.sans(fontSize: 14)),
                  subtitle: Text('Your audio becomes a sound people can add to their videos',
                      style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
                ),
            ] else if (_mode == _ComposerMode.photo) ...[
              if (_imageFile != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.lg),
                  child: Image.file(_imageFile!),
                )
              else
                _PickerBox(icon: Icons.image_outlined, label: 'No photo selected'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickImage(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('Camera'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickImage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Gallery'),
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 16),
            TextField(
              controller: _captionController,
              maxLines: 3,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: _mode == _ComposerMode.text ? "What's on your mind?" : 'Write a caption...',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: AppColors.error, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.text : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
        child: Text(
          label,
          style: AppTypography.sans(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.bg : AppColors.text,
          ),
        ),
      ),
    );
  }
}

class _PickerBox extends StatelessWidget {
  const _PickerBox({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 50),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: AppColors.border, style: BorderStyle.solid),
      ),
      child: Column(
        children: [
          Icon(icon, color: AppColors.muted, size: 32),
          const SizedBox(height: 10),
          Text(label, style: AppTypography.sans(color: AppColors.muted, fontSize: 13)),
        ],
      ),
    );
  }
}
