import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail_plus/video_thumbnail_plus.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../auth/application/auth_controller.dart';
import '../../feed/application/feed_controller.dart';
import '../../profile/data/profile_repository.dart';
import '../../public_feed/application/public_feed_controller.dart';
import '../../sounds/data/sound_repository.dart';
import '../../sounds/presentation/sound_picker_sheet.dart';
import '../data/audio_mix_service.dart';
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

class _ComposerScreenState extends ConsumerState<ComposerScreen> with RouteAware {
  late _ComposerMode _mode = switch (widget.initialMode) {
    'photo' => _ComposerMode.photo,
    'text' => _ComposerMode.text,
    _ => _ComposerMode.video,
  };
  File? _videoFile;
  File? _imageFile;
  VideoPlayerController? _previewController;
  // Plays the chosen sound over the muted-to-mic-level video so the poster can
  // HEAR the mix while dragging the two volume sliders (step 2).
  AudioPlayer? _soundPreview;
  String? _soundPreviewId; // which soundId is currently loaded, to avoid reloads
  final _captionController = TextEditingController();
  bool _uploading = false;
  // Default ON so an uploaded video's sound becomes a reusable, tappable sound
  // (gets a soundId) — otherwise the feed's sound row leads nowhere and "Use
  // this sound" has nothing to open. The toggle still lets the poster opt out.
  bool _soundShareable = true;
  SoundModel? _pickedSound;
  // Mix levels for "use sound": the chosen sound vs the video's own (mic)
  // audio. Set mic to 0 for a pure lip-sync/soundtrack.
  double _soundVolume = 1.0;
  double _micVolume = 1.0;
  // Video is a 3-step wizard: 1 pick/record → 2 edit (sound/volume/caption) →
  // 3 audience + Publish. Photo/Text stay single-step.
  int _videoStep = 1;
  // 'public' = everyone · 'followers' = people who follow you · 'private'.
  String _visibility = 'public';
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) routeObserver.subscribe(this, route);
  }

  // Another screen opened on top — silence the preview so no audio bleeds
  // through from behind it. Resume when we come back.
  @override
  void didPushNext() {
    _previewController?.pause();
    _soundPreview?.pause();
  }

  @override
  void didPopNext() {
    if (_videoStep != 3) _previewController?.play();
    if (_videoStep == 2 && _effectiveSoundId != null) _soundPreview?.play();
  }

  Future<void> _pickSound() async {
    final sound = await showSoundPickerSheet(context);
    if (sound != null) {
      setState(() => _pickedSound = sound);
      _setupSoundPreview();
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _previewController?.dispose();
    _soundPreview?.dispose();
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
    // The video's own audio plays at the "Your audio" level so the mic slider
    // is audible live; the chosen sound is layered on top via _soundPreview.
    await controller.setVolume(_micVolume);
    controller.play();
    if (!mounted) return;
    setState(() {
      _videoFile = file;
      _previewController = controller;
      _videoStep = 2; // a clip is in hand — move to the edit step
    });
    _setupSoundPreview();
  }

  /// Loads and loops the attached sound so step 2 previews the actual mix. No-op
  /// when no sound is attached or it's already loaded. Best-effort (network).
  Future<void> _setupSoundPreview() async {
    final soundId = _effectiveSoundId;
    if (soundId == null) {
      await _soundPreview?.stop();
      return;
    }
    if (_soundPreviewId == soundId && _soundPreview != null) {
      _soundPreview?.play();
      return;
    }
    try {
      var audioUrl = _pickedSound?.audioUrl;
      if (audioUrl == null) {
        final detail = await ref.read(soundRepositoryProvider).fetch(soundId);
        audioUrl = detail.sound.audioUrl;
      }
      if (audioUrl == null || !mounted) return;
      final player = _soundPreview ??= AudioPlayer();
      await player.setLoopMode(LoopMode.one);
      await player.setUrl(mediaUrl(audioUrl));
      await player.setVolume(_soundVolume);
      _soundPreviewId = soundId;
      if (mounted && _videoStep == 2) player.play();
    } catch (_) {/* preview is best-effort; publish still mixes for real */}
  }

  /// First-frame JPEG poster for the upload — the native equivalent of the
  /// web app's makeThumb(). Returns null on failure so posting still succeeds
  /// (the video just falls back to a black cell, as before).
  Future<File?> _makeThumbnail(File video) async {
    try {
      final dir = await getTemporaryDirectory();
      final path = await VideoThumbnailPlus.thumbnailFile(
        video: video.path,
        thumbnailPath: dir.path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 720,
        quality: 75,
      );
      return path != null ? File(path) : null;
    } catch (_) {
      return null;
    }
  }

  /// If a sound is attached, download it and mix it into [video] at the chosen
  /// levels; otherwise return the video untouched. Any failure falls back to
  /// the raw video so publishing still succeeds.
  Future<File> _applySound(File video) async {
    final soundId = _effectiveSoundId;
    if (soundId == null) return video;
    try {
      var audioUrl = _pickedSound?.audioUrl;
      if (audioUrl == null) {
        final detail = await ref.read(soundRepositoryProvider).fetch(soundId);
        audioUrl = detail.sound.audioUrl;
      }
      if (audioUrl == null) return video;
      final dir = await getTemporaryDirectory();
      final soundPath = '${dir.path}/bl_sound_$soundId.m4a';
      await ref.read(dioProvider).download(mediaUrl(audioUrl), soundPath);
      final mixed = await AudioMixService.mixSound(
        videoPath: video.path,
        soundPath: soundPath,
        micVolume: _micVolume,
        soundVolume: _soundVolume,
      );
      return File(mixed);
    } catch (_) {
      return video;
    }
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
        // Mix the chosen sound INTO the video (at the two volumes) before upload.
        final mixed = await _applySound(_videoFile!);
        final fileToUpload = mixed;
        final thumb = await _makeThumbnail(fileToUpload);
        final size = _previewController?.value.size;
        final dur = _previewController?.value.duration;
        uploadedVideoId = await repo.uploadVideo(
          file: fileToUpload,
          caption: _captionController.text.trim(),
          visibility: _visibility,
          soundId: _effectiveSoundId,
          soundShareable: _soundShareable,
          thumbnail: thumb,
          width: size != null && size.width > 0 ? size.width.round() : null,
          height: size != null && size.height > 0 ? size.height.round() : null,
          duration: dur != null && dur > Duration.zero ? dur.inMilliseconds / 1000.0 : null,
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
      // Show the new post immediately everywhere it belongs — no manual
      // refresh: rebuild the feeds and the poster's own profile grid.
      final me = ref.read(authControllerProvider).valueOrNull;
      ref.invalidate(feedControllerProvider(FeedTab.forYou));
      ref.invalidate(feedControllerProvider(FeedTab.following));
      if (_mode == _ComposerMode.video) {
        if (me != null) ref.invalidate(profileProvider(me.username));
      } else {
        ref.invalidate(publicFeedControllerProvider);
        if (me != null) ref.invalidate(profileProvider(me.username));
      }
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

  // ---- video 3-step wizard helpers ----
  bool get _isVideo => _mode == _ComposerMode.video;

  String _stepTitle() {
    if (!_isVideo) return _mode == _ComposerMode.photo ? 'New photo' : 'New post';
    return switch (_videoStep) { 1 => 'New video', 2 => 'Edit', _ => 'Who can see it' };
  }

  /// The primary (top-right) action label, or null when there's nothing to do
  /// yet (video step 1 before a clip is picked).
  String? _primaryLabel() {
    if (_isVideo) return _videoStep == 1 ? null : (_videoStep == 2 ? 'Next' : 'Publish');
    return 'Publish';
  }

  bool _primaryEnabled() => _isVideo ? true : _canPublish;

  void _onPrimary() {
    if (_isVideo && _videoStep == 2) {
      _goToStep(3);
    } else {
      _publish();
    }
  }

  /// Moves between the video wizard steps and keeps the preview audio sane: the
  /// video plays on steps 1–2, the sound only on step 2; step 3 (audience) is
  /// silent so nothing keeps playing behind the picker.
  void _goToStep(int step) {
    setState(() => _videoStep = step);
    step != 3 ? _previewController?.play() : _previewController?.pause();
    (step == 2 && _effectiveSoundId != null) ? _soundPreview?.play() : _soundPreview?.pause();
  }

  Widget _captionField() => TextField(
        controller: _captionController,
        maxLines: 3,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: _mode == _ComposerMode.text ? "What's on your mind?" : 'Write a caption...',
        ),
      );

  @override
  Widget build(BuildContext context) {
    final label = _primaryLabel();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        leading: (_isVideo && _videoStep > 1 && !_uploading)
            ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => _goToStep(_videoStep - 1))
            : null,
        title: Text(_stepTitle()),
        actions: [
          if (label != null)
            TextButton(
              onPressed: (_primaryEnabled() && !_uploading) ? _onPrimary : null,
              child: _uploading
                  ? Text('${(_progress * 100).toStringAsFixed(0)}%')
                  : Text(label),
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
            else if (!_isVideo || _videoStep == 1) ...[
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
              // The clip preview shows on the pick step and the edit step.
              if (_videoStep != 3) ...[
                if (_previewController != null && _previewController!.value.isInitialized)
                  AspectRatio(
                    aspectRatio: _previewController!.value.aspectRatio,
                    child: VideoPlayer(_previewController!),
                  )
                else
                  _PickerBox(icon: Icons.videocam_outlined, label: 'No video selected'),
                const SizedBox(height: 12),
              ],
              // Step 1: record / gallery.
              if (_videoStep == 1)
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
              // Step 2: sound + mix levels + caption.
              if (_videoStep == 2) ...[
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
              // Mix levels — shown whenever a sound is attached (picked here or
              // from a sound page). Slide "Your audio" to 0 for a pure sound.
              if (_effectiveSoundId != null) ...[
                const SizedBox(height: 8),
                Text('VOLUME', style: AppTypography.sectionLabel),
                _VolumeSlider(
                  icon: Icons.music_note,
                  label: 'Sound',
                  value: _soundVolume,
                  onChanged: (v) => setState(() {
                    _soundVolume = v;
                    _soundPreview?.setVolume(v); // hear the change live
                  }),
                ),
                _VolumeSlider(
                  icon: Icons.mic,
                  label: 'Your audio',
                  value: _micVolume,
                  onChanged: (v) => setState(() {
                    _micVolume = v;
                    _previewController?.setVolume(v); // hear the change live
                  }),
                ),
              ],
              const SizedBox(height: 12),
              _captionField(),
              ], // end step 2
              // Step 3: who can see this video.
              if (_videoStep == 3) ...[
                Text('WHO CAN SEE THIS', style: AppTypography.sectionLabel),
                const SizedBox(height: 8),
                _AudienceOption(
                  icon: Icons.public,
                  label: 'Everyone',
                  subtitle: 'Anyone on Belople can watch',
                  value: 'public',
                  group: _visibility,
                  onTap: () => setState(() => _visibility = 'public'),
                ),
                _AudienceOption(
                  icon: Icons.group,
                  label: 'Followers',
                  subtitle: 'Only people who follow you',
                  value: 'followers',
                  group: _visibility,
                  onTap: () => setState(() => _visibility = 'followers'),
                ),
                _AudienceOption(
                  icon: Icons.lock_outline,
                  label: 'Private',
                  subtitle: 'Only you',
                  value: 'private',
                  group: _visibility,
                  onTap: () => setState(() => _visibility = 'private'),
                ),
              ],
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

            // Video puts its caption inside step 2; photo/text show it here.
            if (_mode != _ComposerMode.video) ...[
              const SizedBox(height: 16),
              _captionField(),
            ],
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

/// One audience choice on the video wizard's last step (radio-style).
class _AudienceOption extends StatelessWidget {
  const _AudienceOption({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.group,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final String subtitle;
  final String value;
  final String group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selected = value == group;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? AppColors.accent : AppColors.border, width: selected ? 2 : 1),
        ),
        child: Row(
          children: [
            Icon(icon, size: 22, color: selected ? AppColors.accent : AppColors.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: AppTypography.sans(fontSize: 15, fontWeight: FontWeight.w600)),
                  Text(subtitle, style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
                ],
              ),
            ),
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? AppColors.accent : AppColors.muted, size: 22),
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

/// One 0–100% mix level (the sound, or the video's own audio).
class _VolumeSlider extends StatelessWidget {
  const _VolumeSlider({required this.icon, required this.label, required this.value, required this.onChanged});
  final IconData icon;
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.muted),
        const SizedBox(width: 8),
        SizedBox(
          width: 78,
          child: Text(label, style: AppTypography.sans(fontSize: 13)),
        ),
        Expanded(
          child: Slider(
            value: value,
            onChanged: onChanged,
            activeColor: AppColors.accent,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text('${(value * 100).round()}%',
              textAlign: TextAlign.right,
              style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
        ),
      ],
    );
  }
}
