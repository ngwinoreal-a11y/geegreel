import 'dart:async';
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
import '../data/capture_result.dart';
import '../../../core/widgets/country_picker.dart';
import '../../auth/data/signup_options.dart';
import '../data/audio_mix_service.dart';
import '../data/upload_repository.dart';
import '../data/video_edit_service.dart';
import '../data/video_text_overlay.dart';
import 'camera_filters.dart';
import 'posted_sheet.dart';
import 'text_overlay_editor_screen.dart';
import '../../../core/widgets/top_toast.dart';

enum _ComposerMode { video, photo, text }

/// Ports index.html's uploadPage()/publicUploadPage()/textPostPage() as one
/// screen with a mode switch, matching the reference's single-state-machine
/// approach (see the plan). Live camera preview + in-app recording + the 9
/// filter presets are deferred (the plan's explicit highest-risk item) —
/// this covers the full real publish path (pick from camera roll or record
/// via the OS camera UI, caption, upload with progress, land in the feed)
/// end to end against the real backend.
class ComposerScreen extends ConsumerStatefulWidget {
  const ComposerScreen({
    super.key,
    this.soundId,
    this.videoPath,
    this.imagePath,
    this.initialMode,
    this.filterIndex = 0,
  });

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

  /// The colour look chosen on the viewfinder, as an index into
  /// [kCameraFilters]; 0 is Original. The recorded file is raw footage, so the
  /// look lives here until publish burns it in.
  final int filterIndex;

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
  // audio. Set mic to 0 for a pure lip-sync/soundtrack. The range goes to 200%
  // deliberately: a phone's mic records quiet and library sounds are mastered
  // loud, so with a 100% ceiling there was NO position of either slider that
  // let the video's own audio be heard over the sound.
  double _soundVolume = 1.0;
  double _micVolume = 1.0;
  // Whether the clip has any audio of its own. Null until probed. False means
  // the "Your audio" slider is hidden — there is nothing for it to raise.
  bool? _clipHasAudio;

  /// Text the poster put on the clip, in the order it was added. Burnt into the
  /// file at publish time in the same FFmpeg pass as the look — see
  /// [_applyFilter].
  List<VideoTextOverlay> _textOverlays = [];

  /// The poster deliberately paused the preview. Only a tap sets this — it
  /// exists so [_ensurePreviewPlaying] can restart a clip that stopped on its
  /// own without overriding someone who asked for quiet.
  bool _previewPaused = false;

  /// Last known playing state, so the controller's per-tick notifications only
  /// rebuild when the thing the UI actually shows has changed.
  bool _lastPreviewPlaying = false;

  /// Keeps the clip running on the steps that show it.
  ///
  /// The mix sliders are useless against a still frame: the video's own audio
  /// only exists while the video is playing, so a stopped preview meant the
  /// "Your audio" slider had nothing to raise and only the picked sound could
  /// ever be heard — which is exactly what was reported. Nothing was holding
  /// the preview open; it was started once and never restarted, so anything
  /// that stopped it (a sheet, a rebuild, the end of a clip that didn't loop)
  /// left it stopped for good, with no control to start it again.
  void _ensurePreviewPlaying() {
    if (_previewPaused || _videoStep == 3) return;
    final c = _previewController;
    if (c != null && c.value.isInitialized && !c.value.isPlaying) c.play();
    // BOTH, together. The two levels can only be judged against each other if
    // both tracks are actually running — restarting the clip alone still left
    // half the mix silent whenever the sound had stopped on its own.
    final s = _soundPreview;
    if (_videoStep == 2 && _effectiveSoundId != null && s != null && !s.playing) {
      s.play();
    }
  }

  /// Tap the preview to stop and start it.
  void _togglePreview() {
    final c = _previewController;
    if (c == null || !c.value.isInitialized) return;
    setState(() => _previewPaused = c.value.isPlaying);
    if (c.value.isPlaying) {
      c.pause();
      _soundPreview?.pause();
    } else {
      c.play();
      if (_videoStep == 2 && _effectiveSoundId != null) _soundPreview?.play();
    }
  }

  /// video_player and just_audio both cap at 1.0, so a 160% mic can't be
  /// previewed literally. Preview the RATIO instead — scale both down by the
  /// louder one — which is what the ear judges, and is the same balance
  /// FFmpeg writes on publish now that amix no longer normalizes.
  void _applyPreviewVolumes() {
    final peak = _micVolume > _soundVolume ? _micVolume : _soundVolume;
    final scale = peak > 1.0 ? 1.0 / peak : 1.0;
    _previewController?.setVolume((_micVolume * scale).clamp(0.0, 1.0));
    _soundPreview?.setVolume((_soundVolume * scale).clamp(0.0, 1.0));
  }
  // Video is a 3-step wizard: 1 pick/record → 2 edit (sound/volume/caption) →
  // 3 audience + Publish. Photo/Text stay single-step.
  int _videoStep = 1;
  // 'public' = everyone · 'followers' = people who follow you · 'private'.
  String _visibility = 'public';

  /// Optional targeting the recommender matches against a viewer's signup
  /// choices. Category is one of kInterests — the SAME list people pick their
  /// interests from — so the two sides compare exactly rather than by guess.
  /// One country: it gets shown there most, elsewhere less, never nowhere.
  String? _category;
  String? _country;

  Future<void> _pickCountry() async {
    final picked = await showCountryPicker(context, current: _country);
    // null = dismissed, leave the existing choice; the sentinel = "everywhere".
    if (picked == null || !mounted) return;
    setState(() => _country = picked == kEverywhere ? null : picked);
  }
  double _progress = 0;
  String? _error;

  /// The look to burn in on publish, and what the preview is tinted with so the
  /// two are the same thing. Starts as whatever the viewfinder was wearing;
  /// clearable here, which is also the way out if the render ever fails.
  late int _filterIndex = widget.filterIndex;
  CameraFilter get _filter => kCameraFilters[_filterIndex.clamp(0, kCameraFilters.length - 1)];

  /// What the publish button's percentage is counting right now. Burning a look
  /// in takes real time on a phone, and a bar that silently means two different
  /// things at two different moments is worse than no bar.
  String _stage = 'Uploading';

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

  /// True only while the sound picker is open. That sheet is the one place
  /// where the clip must keep running underneath: you are choosing a sound to
  /// go WITH this video, and you cannot judge that against a frozen frame.
  bool _sheetKeepsClipPlaying = false;

  // Another screen opened on top — silence the preview so no audio bleeds
  // through from behind it. Resume when we come back.
  @override
  void didPushNext() {
    // The picker plays its own preview, so the clip's sound and the sound
    // being auditioned play together — which is exactly the pair you are
    // trying to hear. The composer's own sound preview does stop, so it is
    // two tracks and not three.
    if (!_sheetKeepsClipPlaying) _previewController?.pause();
    _soundPreview?.pause();
  }

  @override
  void didPopNext() {
    if (_videoStep != 3) _previewController?.play();
    if (_videoStep == 2 && _effectiveSoundId != null) _soundPreview?.play();
  }

  Future<void> _pickSound() async {
    _sheetKeepsClipPlaying = true;
    try {
      final sound = await showSoundPickerSheet(context);
      if (sound != null) {
        setState(() => _pickedSound = sound);
        _setupSoundPreview();
      }
    } finally {
      _sheetKeepsClipPlaying = false;
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
    final result = await context.push<CaptureResult>('/camera');
    if (result == null) return;
    switch (result.kind) {
      case CaptureKind.video:
        // The look comes back with the clip and takes over the preview, so
        // step 2 shows what will actually be published.
        if (mounted) setState(() => _filterIndex = result.filterIndex);
        await _loadVideoPreview(File(result.path));
      case CaptureKind.photo:
        if (mounted) {
          setState(() { _imageFile = File(result.path); _mode = _ComposerMode.photo; });
        }
    }
  }

  Future<void> _pickVideo(ImageSource source) async {
    final picked = await _picker.pickVideo(source: source, maxDuration: const Duration(minutes: 1));
    if (picked == null) return;
    // A different clip, and one that was never shot through the viewfinder —
    // it doesn't inherit the previous take's look.
    if (mounted) setState(() => _filterIndex = 0);
    await _loadVideoPreview(File(picked.path));
  }

  Future<void> _loadVideoPreview(File file) async {
    // Text was placed against the clip that is being replaced. Its positions
    // mean nothing on a different frame — and worse, a portrait line dragged to
    // the foot of a portrait clip lands across the middle of a landscape one.
    if (_textOverlays.isNotEmpty && mounted) setState(() => _textOverlays = []);
    _previewController?.dispose();
    final controller = VideoPlayerController.file(file);
    await controller.initialize();
    await controller.setLooping(true);
    // Redraws the play badge the moment the clip stops or starts — and ONLY
    // then. VideoPlayerController notifies on every position tick, several
    // times a second, and rebuilding this whole screen that often made the
    // audio stutter and break up. The badge only depends on isPlaying, so
    // that is the only change worth a rebuild.
    controller.addListener(() {
      final playing = controller.value.isPlaying;
      if (playing != _lastPreviewPlaying && mounted) {
        _lastPreviewPlaying = playing;
        setState(() {});
      }
    });
    // The video's own audio plays at the "Your audio" level so the mic slider
    // is audible live; the chosen sound is layered on top via _soundPreview.
    await controller.setVolume(_micVolume);
    controller.play();
    if (!mounted) return;
    setState(() {
      _videoFile = file;
      _previewController = controller;
      _clipHasAudio = null; // re-probe: this is a different clip
      _videoStep = 2; // a clip is in hand — move to the edit step
    });
    _setupSoundPreview();
    // Probe in the background — the step-2 controls appear immediately and the
    // mic slider settles in once we know whether there's anything to mix.
    unawaited(AudioMixService.hasAudio(file.path).then((has) {
      if (mounted) setState(() => _clipHasAudio = has);
    }));
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
      _applyPreviewVolumes();
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
    } catch (e) {
      // The fallback is complete — the post just gets a black cell — but the
      // reason still goes somewhere it can be read.
      debugPrint('[BLPUB] thumbnail failed, posting without a poster frame: $e');
      return null;
    }
  }

  /// Burns the chosen look into the picture, or returns [video] untouched for
  /// Original.
  ///
  /// Runs BEFORE the sound mix on purpose: this pass re-encodes the picture and
  /// copies the audio, the mix copies the picture and rebuilds the audio, so
  /// between the two the picture is encoded exactly once.
  ///
  /// Throws [VideoEditFailure] — it does not quietly hand back the raw clip.
  /// Publishing footage that doesn't wear the look the poster picked IS the bug
  /// being fixed here, and it went unnoticed for weeks precisely because
  /// nothing said anything.
  Future<File> _applyFilter(File video) async {
    final chain = _filter.ffmpegChain;
    final overlays = _textOverlays.where((o) => !o.isEmpty).toList();
    if (chain == null && overlays.isEmpty) return video;

    // Rendered against the size the PREVIEW was showing, which is what the
    // finger placing the text was pointing at. VideoPlayer reports it with any
    // rotation metadata already applied, so a clip shot sideways gives the
    // upright size here rather than the coded one.
    final overlayPng = await VideoEditService.renderOverlayPng(
      overlays: overlays,
      videoPath: video.path,
      displaySize: _previewController?.value.size,
    );

    if (mounted) {
      setState(() {
        _stage = chain == null
            ? 'Adding your text'
            : (overlayPng == null
                ? 'Applying ${_filter.label}'
                : 'Applying ${_filter.label} and your text');
        _progress = 0;
      });
    }
    final out = await VideoEditService.burnIn(
      videoPath: video.path,
      chain: chain,
      overlayPngPath: overlayPng,
      onProgress: (p) { if (mounted) setState(() => _progress = p); },
    );
    if (mounted) setState(() { _stage = 'Uploading'; _progress = 0; });
    return File(out);
  }

  /// Names what the burn-in pass was carrying, for the message shown when it
  /// fails. "Couldn't apply Original" is what the label alone produced on a
  /// clip whose only edit was text.
  String get _burnInLabel {
    final hasText = _textOverlays.any((o) => !o.isEmpty);
    final hasLook = _filter.ffmpegChain != null;
    if (hasLook && hasText) return 'the ${_filter.label} look and your text';
    if (hasText) return 'your text';
    return 'the ${_filter.label} look';
  }

  /// The burn-in failed. Asks whether to post the clip without it rather than
  /// deciding for them: they may have picked the look on purpose, or they may
  /// just want the video up.
  Future<bool> _askPublishWithoutLook(String name) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text("Couldn't apply $name",
            style: AppTypography.sans(fontSize: 17, fontWeight: FontWeight.w700)),
        content: Text(
          'Your video is fine — only $name failed to render. '
          'Post it without?',
          style: AppTypography.sans(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.accent),
            child: const Text('Post without it'),
          ),
        ],
      ),
    );
    return answer ?? false;
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
    } catch (e) {
      // The video still posts, with its own audio — but a sound that silently
      // fails to arrive is the complaint this whole path was written to fix,
      // so it is said out loud both ways.
      debugPrint('[BLPUB] sound mix failed, posting with the original audio: $e');
      if (mounted) showTopToast(context, "Couldn't add the sound — posting with your own audio");
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
        // Burn the look in, then mix the chosen sound INTO the video (at the
        // two volumes). The thumbnail is taken from the result, so the poster
        // frame wears the look too.
        File filtered;
        try {
          filtered = await _applyFilter(_videoFile!);
        } on VideoEditFailure catch (e) {
          debugPrint('[BLFILTER] $_burnInLabel: $e');
          if (!mounted) return;
          if (!await _askPublishWithoutLook(_burnInLabel)) {
            // finally still clears _uploading.
            setState(() => _error = "Couldn't apply $_burnInLabel — nothing was posted");
            return;
          }
          filtered = _videoFile!;
          if (mounted) setState(() { _stage = 'Uploading'; _progress = 0; });
        }
        final fileToUpload = await _applySound(filtered);
        final thumb = await _makeThumbnail(fileToUpload);
        final size = _previewController?.value.size;
        final dur = _previewController?.value.duration;
        uploadedVideoId = await repo.uploadVideo(
          file: fileToUpload,
          caption: _captionController.text.trim(),
          visibility: _visibility,
          category: _category,
          country: _country,
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
        showTopToast(context, 'Posted!');
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
    // Moving between steps is a fresh start — a pause asked for on one step
    // shouldn't follow you to the next.
    setState(() { _videoStep = step; _previewPaused = false; });
    step != 3 ? _previewController?.play() : _previewController?.pause();
    (step == 2 && _effectiveSoundId != null) ? _soundPreview?.play() : _soundPreview?.pause();
  }

  /// Wraps [child] in the selected look, or returns it untouched for Original.
  Widget _tinted(Widget child) {
    final f = _filter.colorFilter;
    return f == null ? child : ColorFiltered(colorFilter: f, child: child);
  }

  /// Opens the text editor on this clip and takes back whatever came out of it.
  /// A null result is the poster backing out, which keeps what they had.
  Future<void> _editText() async {
    final video = _videoFile;
    if (video == null) return;
    // The clip carries on playing behind a full-screen editor otherwise, with
    // its sound, under a screen that has nothing to do with either.
    _previewController?.pause();
    _soundPreview?.pause();
    final result = await Navigator.of(context).push<List<VideoTextOverlay>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => TextOverlayEditorScreen(
          videoPath: video.path,
          overlays: _textOverlays,
          tint: _filter.colorFilter,
        ),
      ),
    );
    if (!mounted) return;
    if (result != null) setState(() => _textOverlays = result);
    // Back on step 2, where both are supposed to be running.
    _previewController?.play();
    if (_effectiveSoundId != null) _soundPreview?.play();
  }

  /// The `Aa` tool. Reads as "Text" until there is some, then says how much, so
  /// the button is also the only place that reports what is on the clip.
  Widget _textButton() {
    final count = _textOverlays.where((o) => !o.isEmpty).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: OutlinedButton.icon(
        onPressed: _uploading ? null : _editText,
        icon: const Text('Aa',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, height: 1)),
        label: Text(switch (count) {
          0 => 'Add text',
          1 => 'Edit text (1)',
          _ => 'Edit text ($count)',
        }),
      ),
    );
  }

  /// Names the look riding on this clip and offers the one way to take it off.
  /// It is also the recovery path when the render fails — without it, dropping
  /// a look would mean re-recording the whole take.
  Widget _filterChip() => Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.only(left: 14, right: 4, top: 2, bottom: 2),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_awesome, size: 16, color: AppColors.accent),
            const SizedBox(width: 8),
            Text(_filter.label,
                style: AppTypography.sans(fontSize: 13.5, fontWeight: FontWeight.w600)),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 17, color: AppColors.muted),
              tooltip: 'Remove this look',
              onPressed: _uploading ? null : () => setState(() => _filterIndex = 0),
            ),
          ],
        ),
      );

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
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TextButton(
                onPressed: (_primaryEnabled() && !_uploading) ? _onPrimary : null,
                // Amber on the bar's black, big, and with no outline. This is
                // the one way forward on the screen and it was reading as
                // ordinary grey chrome next to the title.
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.accent,
                  disabledForegroundColor: AppColors.faint,
                  textStyle: AppTypography.sans(fontSize: 19, fontWeight: FontWeight.w800),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                ),
                child: _uploading
                    ? Text('${(_progress * 100).toStringAsFixed(0)}%')
                    : Text(label),
              ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Says what the percentage on the button is counting. Burning a
            // look in can outlast the upload that follows it, and a bar sitting
            // at 40% with no word for it reads as a stuck app.
            //
            // It goes FIRST, not at the foot of the page: on the audience step
            // the category chips run well past the bottom of the screen, so a
            // status line below them is one nobody publishing ever sees. That
            // is exactly how it shipped on the device the first time.
            if (_uploading) ...[
              Row(
                children: [
                  Text('$_stage…',
                      style: AppTypography.sans(fontSize: 13, color: AppColors.muted)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: _progress == 0 ? null : _progress,
                        minHeight: 4,
                        backgroundColor: AppColors.surface,
                        valueColor: const AlwaysStoppedAnimation(AppColors.accent),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
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
                  // Re-asserted every time this step is drawn, so the clip is
                  // running while the sliders are on screen — they can only be
                  // judged against audio that is actually playing.
                  Builder(builder: (context) {
                    WidgetsBinding.instance.addPostFrameCallback((_) => _ensurePreviewPlaying());
                    return GestureDetector(
                      onTap: _togglePreview,
                      child: AspectRatio(
                        aspectRatio: _previewController!.value.aspectRatio,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Tinted with the very matrix FFmpeg will burn in,
                            // so this preview is the promise the file keeps —
                            // the look used to live on the viewfinder only and
                            // vanish the moment you stopped recording.
                            _tinted(VideoPlayer(_previewController!)),
                            // The text, drawn by the very painter that renders
                            // the PNG FFmpeg burns in — so this preview is the
                            // same promise the look above it makes.
                            if (_textOverlays.isNotEmpty)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: CustomPaint(
                                    painter: OverlayLayerPainter(_textOverlays),
                                  ),
                                ),
                              ),
                            // Only when stopped: something to press, and a sign
                            // that the silence is a paused clip rather than a
                            // broken one.
                            if (_previewPaused || !_previewController!.value.isPlaying)
                              Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.5),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 38),
                              ),
                          ],
                        ),
                      ),
                    );
                  })
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
              // Step 2: text + look + sound + mix levels + caption.
              if (_videoStep == 2) ...[
              _textButton(),
              if (_filterIndex != 0) _filterChip(),
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
                    _applyPreviewVolumes(); // hear the change live
                  }),
                ),
                // Hidden once we know the clip is silent: there is no "your
                // audio" to raise, and leaving the slider there is what made
                // it look like the control was broken.
                if (_clipHasAudio != false)
                  _VolumeSlider(
                    icon: Icons.mic,
                    label: 'Your audio',
                    value: _micVolume,
                    onChanged: (v) => setState(() {
                      _micVolume = v;
                      _applyPreviewVolumes(); // hear the change live
                    }),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(children: [
                      const Icon(Icons.mic_off, size: 18, color: AppColors.muted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('This clip was recorded without sound',
                            style: AppTypography.sans(fontSize: 13, color: AppColors.muted)),
                      ),
                    ]),
                  ),
              ],
              // The caption lives on the publish step, beside the clip it
              // belongs to. A second one here asked the same question twice.
              ], // end step 2
              // Step 3: who can see this video.
              if (_videoStep == 3) ...[
                // Caption beside the clip it belongs to. On the previous
                // layout the publish step showed audience options with no
                // sight of the video at all, so the last thing you saw before
                // posting wasn't what you were posting.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _captionField()),
                    const SizedBox(width: 12),
                    if (_previewController?.value.isInitialized ?? false)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadii.md),
                        child: SizedBox(
                          width: 84,
                          height: 112,
                          child: FittedBox(
                            fit: BoxFit.cover,
                            child: SizedBox(
                              width: _previewController!.value.size.width,
                              height: _previewController!.value.size.height,
                              // The audience step's thumbnail wears the look
                              // AND the text — it is the last thing seen before
                              // Publish, and it showed a clip with no text on it
                              // right up to the moment of posting one with.
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  _tinted(VideoPlayer(_previewController!)),
                                  if (_textOverlays.isNotEmpty)
                                    CustomPaint(painter: OverlayLayerPainter(_textOverlays)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 22),
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

                const SizedBox(height: 22),
                // Category and country are what the recommender matches a
                // viewer's own signup choices against. Both are optional — a
                // video with neither still ranks, Belo Flow just falls back to
                // reading topics out of the caption, which guesses.
                Text('CATEGORY', style: AppTypography.sectionLabel),
                const SizedBox(height: 6),
                Text('Belople shows this to people who chose the same interest',
                    style: AppTypography.sans(fontSize: 13, color: AppColors.muted)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in kInterests)
                      _ChoiceChip(
                        label: c,
                        selected: _category == c,
                        // Tapping the chosen one clears it.
                        onTap: () => setState(() => _category = _category == c ? null : c),
                      ),
                  ],
                ),

                const SizedBox(height: 22),
                Text('COUNTRY', style: AppTypography.sectionLabel),
                const SizedBox(height: 6),
                Text(
                  _country == null
                      ? 'Everywhere — anyone can be shown this'
                      : 'Shown most in $_country, less elsewhere',
                  style: AppTypography.sans(fontSize: 13, color: AppColors.muted),
                ),
                const SizedBox(height: 10),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _pickCountry,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
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
                        if (_country != null)
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setState(() => _country = null),
                            child: const Icon(Icons.close, size: 20, color: AppColors.muted),
                          )
                        else
                          const Icon(Icons.chevron_right, color: AppColors.muted),
                      ],
                    ),
                  ),
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

/// One 0–200% mix level (the sound, or the video's own audio). 100% is the
/// track as recorded; above that it is boosted, which is the only way a quiet
/// phone-mic recording can hold its own against a mastered library sound.
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
            max: 2.0,
            divisions: 40, // 5% steps — fine enough to tune, coarse enough to hit
            onChanged: onChanged,
            activeColor: AppColors.accent,
          ),
        ),
        SizedBox(
          width: 46,
          child: Text('${(value * 100).round()}%',
              textAlign: TextAlign.right,
              style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
        ),
      ],
    );
  }
}

/// A selectable pill for the category list. Brand amber when chosen, so the one
/// picked out of seventeen is obvious at a glance.
class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? AppColors.accent : AppColors.border),
        ),
        child: Text(
          label,
          style: AppTypography.sans(
            fontSize: 15,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? AppColors.accent : AppColors.text,
          ),
        ),
      ),
    );
  }
}
