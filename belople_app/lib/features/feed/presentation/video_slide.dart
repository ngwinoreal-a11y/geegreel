import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../../../core/network/api_client.dart';
import '../application/playback_speed.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../data/video_model.dart';

/// Ports design-feed.css: full-bleed video (object-fit: cover), no black
/// band at top, a short black strip at the bottom behind the nav pill/scrub
/// bar only — author/caption/rail float directly on the picture with a text
/// shadow, same as the top icons.
class VideoSlide extends ConsumerStatefulWidget {
  const VideoSlide({
    super.key,
    required this.video,
    required this.isActive,
    this.onLikeTap,
    this.onFollowTap,
    this.onAuthorTap,
    this.onCommentTap,
    this.onMoreTap,
    this.onSoundTap,
    this.onShareTap,
    this.onGiftTap,
    this.onRepostTap,
  });

  final VideoModel video;
  final bool isActive;
  final VoidCallback? onLikeTap;
  final VoidCallback? onFollowTap;
  final VoidCallback? onAuthorTap;
  final VoidCallback? onCommentTap;
  final VoidCallback? onMoreTap;
  final VoidCallback? onSoundTap;
  final VoidCallback? onShareTap;
  final VoidCallback? onGiftTap;
  final VoidCallback? onRepostTap;

  @override
  ConsumerState<VideoSlide> createState() => _VideoSlideState();
}

class _VideoSlideState extends ConsumerState<VideoSlide> with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _showHeartBurst = false;
  bool _showPauseGlyph = false;
  bool _pausedByLifecycle = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setup();
  }

  // Backgrounding the app (home button, phone lock, app switch) has no
  // effect on a plain VideoPlayerController by itself — without this it
  // kept playing (and making sound) with the screen off. FeedScreen's
  // RouteAware handles the in-app "navigated to another screen" case;
  // this handles leaving the app entirely.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null) return;
    if (state == AppLifecycleState.resumed) {
      if (_pausedByLifecycle && widget.isActive) {
        _controller!.play();
      }
      _pausedByLifecycle = false;
    } else {
      if (_controller!.value.isPlaying) {
        _controller!.pause();
        _pausedByLifecycle = true;
      }
    }
  }

  Future<void> _setup() async {
    // An image ad has no video to play — it's rendered as a still in build().
    if (widget.video.isImageAd) return;
    final url = mediaUrl(widget.video.videoUrl);
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    _controller = controller;
    await controller.initialize();
    await controller.setLooping(true);
    await controller.setPlaybackSpeed(ref.read(playbackSpeedProvider));
    if (!mounted) return;
    setState(() => _initialized = true);
    if (widget.isActive) controller.play();
  }

  @override
  void didUpdateWidget(covariant VideoSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive != oldWidget.isActive && _controller != null) {
      widget.isActive ? _controller!.play() : _controller!.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    if (_controller == null) return;
    setState(() {
      if (_controller!.value.isPlaying) {
        _controller!.pause();
        _showPauseGlyph = true;
      } else {
        _controller!.play();
        _showPauseGlyph = false;
      }
    });
  }

  void _onDoubleTap() {
    if (!widget.video.liked) widget.onLikeTap?.call();
    setState(() => _showHeartBurst = true);
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _showHeartBurst = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Apply speed changes made from the "•••" sheet to the live controller.
    ref.listen<double>(playbackSpeedProvider, (_, next) => _controller?.setPlaybackSpeed(next));
    return GestureDetector(
      onTap: _togglePlayPause,
      onDoubleTap: _onDoubleTap,
      child: Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.black),
        if (widget.video.isImageAd)
          // Image ad: the sponsor's still image, shown full-bleed.
          CachedNetworkImage(imageUrl: mediaUrl(widget.video.videoUrl), fit: BoxFit.contain, width: double.infinity)
        else if (_initialized && _controller != null)
          FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _controller!.value.size.width,
              height: _controller!.value.size.height,
              child: VideoPlayer(_controller!),
            ),
          )
        else if (widget.video.thumbUrl != null)
          CachedNetworkImage(imageUrl: mediaUrl(widget.video.thumbUrl!), fit: BoxFit.cover),

        // Pause glyph — design-5.css: faint, only while paused-by-tap.
        if (_showPauseGlyph)
          const Center(
            child: Icon(Icons.pause, color: Colors.white38, size: 62),
          ),

        // Heart burst — double-tap-to-like feedback.
        if (_showHeartBurst)
          Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.4, end: 1.2),
              duration: const Duration(milliseconds: 350),
              curve: Curves.elasticOut,
              builder: (context, scale, child) => Transform.scale(
                scale: scale,
                child: child,
              ),
              child: const Icon(Icons.favorite, color: Colors.white, size: 100),
            ),
          ),

        // C. bottom black strip (nav pill + scrub bar floor only)
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 112,
          child: ColoredBox(color: Colors.black),
        ),

        // A. video progress bar (scrubber) — sits just above the nav pill,
        // fills as the video plays, and can be dragged to seek. Mirrors
        // design-5.css's `.scrub` (bottom ~84px, drag-to-seek).
        if (_initialized && _controller != null)
          Positioned(
            left: 8,
            right: 8,
            bottom: 96,
            child: _Scrubber(controller: _controller!),
          ),

        // D. author/caption, floating on the picture
        Positioned(
          left: 16,
          right: 76,
          bottom: 116,
          child: DefaultTextStyle(
            style: const TextStyle(
              shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    GestureDetector(
                      onTap: widget.onAuthorTap,
                      child: AppAvatar(
                        size: 44,
                        imageUrl: widget.video.user.avatarUrl != null
                            ? mediaUrl(widget.video.user.avatarUrl!)
                            : null,
                        displayName: widget.video.user.displayName,
                        borderColor: Colors.white,
                        borderWidth: 2,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: GestureDetector(
                      onTap: widget.onAuthorTap,
                      child: Text(
                        widget.video.user.displayName,
                        style: AppTypography.sans(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      ),
                    ),
                    if (widget.onFollowTap != null) ...[
                      const SizedBox(width: 8),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onFollowTap,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                          decoration: BoxDecoration(
                            color: widget.video.following
                                ? Colors.white.withValues(alpha: 0.18)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            widget.video.following ? 'Following' : 'Follow',
                            style: AppTypography.sans(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: widget.video.following
                                  ? Colors.white.withValues(alpha: 0.75)
                                  : AppColors.onChrome,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (widget.video.isAd) ...[
                  const SizedBox(height: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.sponsor.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('Sponsored',
                        style: AppTypography.sans(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.onChrome)),
                  ),
                ],
                if (widget.video.caption.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    widget.video.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.sans(fontSize: 14, color: Colors.white),
                  ),
                ],
                if (widget.video.isAd && widget.video.linkUrl != null) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () => launchUrl(Uri.parse(widget.video.linkUrl!), mode: LaunchMode.externalApplication),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(widget.video.ctaText ?? 'Learn more',
                              style: AppTypography.sans(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.onChrome)),
                          const SizedBox(width: 4),
                          const Icon(Icons.open_in_new, size: 14, color: AppColors.onChrome),
                        ],
                      ),
                    ),
                  ),
                ],
                if (widget.video.song != null) ...[
                  const SizedBox(height: 4),
                  GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onSoundTap,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.music_note, size: 12, color: Colors.white),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          widget.video.song!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.sans(fontSize: 13, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // Right-hand action rail
        Positioned(
          right: 10,
          bottom: 116,
          child: _ActionRail(
            video: widget.video,
            onLikeTap: widget.onLikeTap,
            onCommentTap: widget.onCommentTap,
            onMoreTap: widget.onMoreTap,
            onShareTap: widget.onShareTap,
            onGiftTap: widget.onGiftTap,
            onRepostTap: widget.onRepostTap,
            onSoundTap: widget.onSoundTap,
          ),
        ),
      ],
      ),
    );
  }
}

class _ActionRail extends StatelessWidget {
  const _ActionRail({
    required this.video,
    this.onLikeTap,
    this.onCommentTap,
    this.onMoreTap,
    this.onShareTap,
    this.onGiftTap,
    this.onRepostTap,
    this.onSoundTap,
  });
  final VideoModel video;
  final VoidCallback? onLikeTap;
  final VoidCallback? onCommentTap;
  final VoidCallback? onMoreTap;
  final VoidCallback? onShareTap;
  final VoidCallback? onGiftTap;
  final VoidCallback? onRepostTap;
  final VoidCallback? onSoundTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onLikeTap,
          child: _RailButton(
            icon: video.liked ? Icons.favorite : Icons.favorite_border,
            color: video.liked ? AppColors.badge : Colors.white,
            count: video.counts.likes,
          ),
        ),
        const SizedBox(height: 22),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onCommentTap,
          child: _RailButton(icon: Icons.mode_comment, color: Colors.white, count: video.counts.comments),
        ),
        const SizedBox(height: 22),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onRepostTap,
          child: _RailButton(icon: Icons.repeat_rounded, color: Colors.white, count: video.counts.reposts),
        ),
        const SizedBox(height: 22),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onShareTap,
          child: _RailButton(icon: Icons.reply, color: Colors.white, count: video.counts.shares, flipX: true),
        ),
        const SizedBox(height: 22),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onGiftTap,
          child: _RailButton(icon: Icons.card_giftcard, color: AppColors.accent, count: video.giftCoins),
        ),
        const SizedBox(height: 22),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onMoreTap,
          child: const Icon(Icons.more_vert, color: Colors.white, size: 28),
        ),
        const SizedBox(height: 22),
        // Spinning sound disc (design's `.sound-disc`) — the sound's art on
        // the rail; tapping opens the sound page / its owner.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onSoundTap,
          child: _SoundDisc(thumbUrl: video.thumbUrl),
        ),
      ],
    );
  }
}

/// The video progress bar. A thin track fills to the current position and can
/// be tapped or dragged to seek. Ports design-5.css's `.scrub`: 2.5px resting
/// height, white fill on a faint track, a knob while dragging.
class _Scrubber extends StatefulWidget {
  const _Scrubber({required this.controller});
  final VideoPlayerController controller;

  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> {
  bool _dragging = false;

  void _seekTo(double dx, double width) {
    final dur = widget.controller.value.duration;
    if (dur.inMilliseconds == 0 || width <= 0) return;
    final ratio = (dx / width).clamp(0.0, 1.0);
    widget.controller.seekTo(dur * ratio);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: widget.controller,
          builder: (context, value, _) {
            final durMs = value.duration.inMilliseconds;
            final posMs = value.position.inMilliseconds;
            final frac = durMs > 0 ? (posMs / durMs).clamp(0.0, 1.0) : 0.0;
            final h = _dragging ? 5.0 : 2.5;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _seekTo(d.localPosition.dx, width),
              onHorizontalDragStart: (_) => setState(() => _dragging = true),
              onHorizontalDragUpdate: (d) => _seekTo(d.localPosition.dx, width),
              onHorizontalDragEnd: (_) => setState(() => _dragging = false),
              child: SizedBox(
                height: 20,
                child: Center(
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        height: h,
                        decoration: BoxDecoration(color: AppColors.scrubTrack, borderRadius: BorderRadius.circular(3)),
                      ),
                      FractionallySizedBox(
                        widthFactor: frac,
                        child: Container(
                          height: h,
                          decoration: BoxDecoration(color: AppColors.scrubFill, borderRadius: BorderRadius.circular(3)),
                        ),
                      ),
                      if (_dragging)
                        Positioned(
                          left: (frac * width) - 7,
                          child: Container(
                            width: 14, height: 14,
                            decoration: const BoxDecoration(color: AppColors.scrubFill, shape: BoxShape.circle),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// A slowly rotating circular disc showing the sound's artwork (the video
/// thumbnail), ringed in white — TikTok's spinning album art.
class _SoundDisc extends StatefulWidget {
  const _SoundDisc({required this.thumbUrl});
  final String? thumbUrl;

  @override
  State<_SoundDisc> createState() => _SoundDiscState();
}

class _SoundDiscState extends State<_SoundDisc> with SingleTickerProviderStateMixin {
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 5))..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _spin,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.raised,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6)],
        ),
        clipBehavior: Clip.antiAlias,
        child: widget.thumbUrl != null
            ? CachedNetworkImage(imageUrl: mediaUrl(widget.thumbUrl!), fit: BoxFit.cover)
            : const Center(child: Icon(Icons.music_note, color: Colors.white, size: 20)),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({required this.icon, required this.color, required this.count, this.flipX = false});
  final IconData icon;
  final Color color;
  final int count;
  final bool flipX;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(icon, color: color, size: 30, shadows: const [Shadow(color: Colors.black54, blurRadius: 6)]);
    return Column(
      children: [
        flipX ? Transform.flip(flipX: true, child: glyph) : glyph,
        const SizedBox(height: 4),
        Text(
          _formatCount(count),
          style: AppTypography.mono(fontSize: 12, color: Colors.white).copyWith(
            shadows: const [Shadow(color: Colors.black87, blurRadius: 6)],
          ),
        ),
      ],
    );
  }

  static String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}
