import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/app_router.dart';
import '../../auth/application/auth_controller.dart';
import '../application/playback_speed.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/brand_refresh.dart';
import '../data/video_model.dart';
import '../data/feed_repository.dart';

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
    this.onAdClick,
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
  /// Fired when the ad's CTA is tapped, to record a click (user ads).
  final VoidCallback? onAdClick;

  @override
  ConsumerState<VideoSlide> createState() => _VideoSlideState();
}

class _VideoSlideState extends ConsumerState<VideoSlide> with WidgetsBindingObserver, RouteAware {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _showHeartBurst = false;
  bool _showPauseGlyph = false;
  bool _captionExpanded = false;

  // --- The four things that decide whether this slide may make sound. They
  // live HERE, not in each host screen: SingleVideoScreen was a plain
  // ConsumerWidget passing isActive:true with no RouteAware, so opening a
  // profile on top of it left the video playing underneath. Owning the rule in
  // the player means every host (feed, profile videos, single video, anything
  // added later) gets it right without having to remember to. ---

  /// Another route has been pushed over the screen showing this slide.
  bool _routeCovered = false;

  /// The app itself is backgrounded (home button, lock, app switch).
  bool _appBackgrounded = false;

  /// The user tapped to pause — never auto-resume over their choice.
  bool _pausedByUser = false;

  bool get _shouldPlay =>
      widget.isActive && !_routeCovered && !_appBackgrounded && !_pausedByUser;

  /// Single place that drives the player. Everything that can change playback
  /// (activation, route, lifecycle, tap) just updates a flag and calls this.
  void _applyPlayback() {
    final controller = _controller;
    if (controller == null || !_initialized) return;
    if (_shouldPlay) {
      if (!controller.value.isPlaying) controller.play();
      if (!_watch.isRunning) _watch.start();
    } else {
      if (controller.value.isPlaying) controller.pause();
      _watch.stop();
    }
  }

  // Belo Flow watch tracking: wall-clock time this slide was the active,
  // foreground video — a robust proxy for watch time that feeds the
  // recommender. Reported once when the user swipes away (or on dispose).
  final Stopwatch _watch = Stopwatch();
  bool _watchReported = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setup();
    if (widget.isActive) _watch.start();
  }

  // Backgrounding the app (home button, phone lock, app switch) has no
  // effect on a plain VideoPlayerController by itself — without this it
  // kept playing (and making sound) with the screen off.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appBackgrounded = state != AppLifecycleState.resumed;
    _applyPlayback();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) routeObserver.subscribe(this, route);
    _applyPlayback(); // idempotent — re-asserts the rule after any tree change
  }

  // A screen was pushed over ours (profile, sound, comments-as-a-route…).
  @override
  void didPushNext() {
    _routeCovered = true;
    _applyPlayback();
  }

  // That screen was popped — ours is on top again.
  @override
  void didPopNext() {
    _routeCovered = false;
    _applyPlayback();
  }

  // Reports the watch to Belo Flow exactly once per active viewing. watch time
  // comes from the stopwatch; the duration from the player. A very short watch
  // is flagged as an early swipe (negative signal); looping past the full
  // duration counts as a replay (positive signal).
  void _reportWatch() {
    if (_watchReported) return;
    final c = _controller;
    if (c == null || !_initialized) return; // nothing to report for image ads
    if (widget.video.isAd) return;          // ads track impressions separately
    _watch.stop();
    final watchMs = _watch.elapsedMilliseconds;
    if (watchMs < 300) return;              // ignore incidental flashes
    final durationMs = c.value.duration.inMilliseconds;
    final replayed = durationMs > 0 && watchMs > durationMs * 1.5;
    final skipped = durationMs > 0 && watchMs < 2000 && watchMs < durationMs * 0.2;
    _watchReported = true;
    ref.read(feedRepositoryProvider).recordWatch(
          widget.video.id,
          watchMs: watchMs,
          durationMs: durationMs,
          replayed: replayed,
          skipped: skipped,
        );
  }

  Future<void> _setup() async {
    // An image ad has no video to play — it's rendered as a still in build().
    if (widget.video.isImageAd) return;
    final url = mediaUrl(widget.video.videoUrl);
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    _controller = controller;
    try {
      await controller.initialize();
    } catch (_) {
      return; // network/codec failure — leave the thumbnail showing
    }
    // The user can swipe or navigate away while a network video is still
    // initializing. Once init finishes, bail (and dispose) if we're no longer
    // mounted so a just-finished controller can't start playing off-screen.
    if (!mounted) {
      await controller.dispose();
      return;
    }
    await controller.setLooping(true);
    await controller.setPlaybackSpeed(ref.read(playbackSpeedProvider));
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() => _initialized = true);
    // Not `if (widget.isActive) play()` — by the time a network video finishes
    // initializing the route may already be covered or the app backgrounded.
    _applyPlayback();
  }

  @override
  void didUpdateWidget(covariant VideoSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      // Became the active video: a fresh slide starts unpaused, and begins a
      // fresh watch measurement.
      _pausedByUser = false;
      _watchReported = false;
      _watch.reset();
    } else if (!widget.isActive && oldWidget.isActive) {
      // Swiped away: report what was watched.
      _reportWatch();
    }
    if (widget.isActive != oldWidget.isActive) _applyPlayback();
  }

  // Removed from the tree — route popped/replaced, or the page recycled. Stop
  // the sound NOW: dispose() runs later and, if anything in it throws, a
  // still-playing controller would be orphaned and audible with nothing on
  // screen to stop it.
  @override
  void deactivate() {
    _controller?.pause();
    super.deactivate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    routeObserver.unsubscribe(this);
    // Report the watch, but NEVER let it stop us from disposing the player:
    // _reportWatch() reads providers through `ref`, which can throw during
    // teardown ("Cannot use ref after the widget was disposed"). If that threw
    // here it unwound dispose() before _controller.dispose() ran, orphaning a
    // *playing* controller — so leaving a video mid-playback kept its audio
    // going off-screen (a paused one skipped this path, hence "only when I
    // didn't pause"). Guard it, and always dispose the controller after.
    if (widget.isActive) {
      try {
        _reportWatch(); // still active at teardown — capture it
      } catch (_) {}
    }
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    if (_controller == null || !_initialized) return;
    setState(() {
      // Playing now → this tap pauses it, and that's the user's choice to keep.
      _pausedByUser = _controller!.value.isPlaying;
      _showPauseGlyph = _pausedByUser;
    });
    _applyPlayback();
  }

  void _onDoubleTap() {
    if (!widget.video.liked) widget.onLikeTap?.call();
    setState(() => _showHeartBurst = true);
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _showHeartBurst = false);
    });
  }

  /// The signed-in user is this video's author — used to hide repost/gift on
  /// your own video (you can't repost or tip yourself), matching the web.
  bool get _isMine {
    final me = ref.watch(authControllerProvider).valueOrNull;
    return me != null && me.id == widget.video.user.id;
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
          // Image ad: the sponsor's still image, shown full-bleed. Ads carry no
          // poster frame, so without a placeholder the slide is a black panel
          // for the whole download — the "ads take ages to open" complaint.
          // No placeholder on purpose: the feed pre-caches ad media as soon as
          // the page loads (see FeedScreen._precacheAds), so by the time an ad
          // is swiped to it's already decoded and paints on the first frame.
          // A spinner here would only ever be seen if that pre-cache lost a
          // race, and a flash of one is worse than none.
          CachedNetworkImage(
            imageUrl: mediaUrl(widget.video.videoUrl),
            fit: BoxFit.contain,
            width: double.infinity,
            fadeInDuration: Duration.zero,
          )
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
          CachedNetworkImage(imageUrl: mediaUrl(widget.video.thumbUrl!), fit: BoxFit.cover)
        else
          // No poster to show (video ads don't have one) — the dots say the
          // app is working rather than leaving a dead black frame.
          const Center(child: BrandRefreshDots()),

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
            // Isolate the scrubber's per-frame repaints from the rest of the
            // slide so tracking the playhead doesn't repaint the video layer.
            child: RepaintBoundary(child: _Scrubber(controller: _controller!)),
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
                // "Reposted by" line with the reposter's small avatar — shown
                // above the original creator's author row. (For a repost the
                // backend puts the original creator in repostOf and the
                // reposter in user.)
                if (widget.video.isRepost) ...[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppAvatar(
                        size: 18,
                        imageUrl: widget.video.user.avatarUrl != null
                            ? mediaUrl(widget.video.user.avatarUrl!)
                            : null,
                        displayName: widget.video.user.displayName,
                      ),
                      const SizedBox(width: 6),
                      Text('Reposted',
                          style: AppTypography.sans(
                              fontSize: 12, fontWeight: FontWeight.w500, color: Colors.white)),
                    ],
                  ),
                  const SizedBox(height: 6),
                ],
                // A real post — and a self-serve USER ad — shows the author
                // (the sponsor for ads, the original creator for reposts) +
                // follow. A house/admin ad shows neither.
                if (!widget.video.isAd || widget.video.isUserAd)
                Row(
                  children: [
                    GestureDetector(
                      onTap: widget.onAuthorTap,
                      child: AppAvatar(
                        size: 44,
                        imageUrl: (widget.video.repostOf ?? widget.video.user).avatarUrl != null
                            ? mediaUrl((widget.video.repostOf ?? widget.video.user).avatarUrl!)
                            : null,
                        displayName: (widget.video.repostOf ?? widget.video.user).displayName,
                        borderColor: Colors.white,
                        borderWidth: 2,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: GestureDetector(
                      onTap: widget.onAuthorTap,
                      child: Text(
                        (widget.video.repostOf ?? widget.video.user).displayName,
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
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.sponsor.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('Ad',
                        style: AppTypography.sans(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.onChrome)),
                  ),
                  // Admin ads name their sponsor here (user ads already show the
                  // creator in the author row above).
                  if (!widget.video.isUserAd && widget.video.sponsorName != null) ...[
                    const SizedBox(height: 6),
                    Text(widget.video.sponsorName!,
                        style: AppTypography.sans(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                  ],
                ],
                if (widget.video.caption.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _captionExpanded = !_captionExpanded),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.video.caption,
                          maxLines: _captionExpanded ? null : 1,
                          overflow: _captionExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                          style: AppTypography.sans(fontSize: 14, color: Colors.white),
                        ),
                        // "more"/"less" toggle — only when the caption is long
                        // enough to actually be clipped on one line.
                        if (widget.video.caption.length > 42)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              _captionExpanded ? 'less' : 'more',
                              style: AppTypography.sans(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Colors.white.withValues(alpha: 0.75),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if (widget.video.isAd && widget.video.linkUrl != null) ...[
                  const SizedBox(height: 10),
                  GestureDetector(
                    onTap: () {
                      widget.onAdClick?.call();
                      launchUrl(Uri.parse(widget.video.linkUrl!), mode: LaunchMode.externalApplication);
                    },
                    child: Container(
                      width: 260,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF25D366), // WhatsApp/CTA green, as in the refs
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(widget.video.ctaText ?? 'Learn more',
                                style: AppTypography.sans(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                          ),
                          const Icon(Icons.chevron_right, size: 22, color: Colors.white),
                        ],
                      ),
                    ),
                  ),
                ],
                if (!widget.video.isAd && widget.video.song != null) ...[
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

        // Right-hand action rail. A house/admin ad shows only a like button;
        // a self-serve USER ad gets the full rail (like/comment/share/more —
        // no gift/repost/sound), like the Instagram-style ad references.
        Positioned(
          right: 10,
          bottom: 116,
          child: (widget.video.isAd && !widget.video.isUserAd)
              ? GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onLikeTap,
                  child: _RailButton(
                    icon: Icons.favorite_rounded,
                    color: widget.video.liked ? AppColors.badge : Colors.white,
                    count: widget.video.counts.likes,
                    size: 33,
                  ),
                )
              : _ActionRail(
                  video: widget.video,
                  // Ads never show gift/repost/sound — reuse the "mine" hiding.
                  isMine: _isMine || widget.video.isUserAd,
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
    this.isMine = false,
    this.onLikeTap,
    this.onCommentTap,
    this.onMoreTap,
    this.onShareTap,
    this.onGiftTap,
    this.onRepostTap,
    this.onSoundTap,
  });
  final VideoModel video;
  final bool isMine;
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
        // Every glyph is SOLID. The rail used to mix fills — an outline heart
        // and bubble beside a solid paper plane and gift — which is what read as
        // "badly made"; solid also survives a bright frame far better than a
        // 2px outline does.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onLikeTap,
          child: _RailButton(
            icon: Icons.favorite_rounded,
            color: video.liked ? AppColors.badge : Colors.white,
            count: video.counts.likes,
            size: 33,
          ),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onCommentTap,
          child: _RailButton(
            icon: Icons.mode_comment_rounded,
            color: Colors.white,
            count: video.counts.comments,
            size: 29,
          ),
        ),
        const SizedBox(height: 16),
        // Repost and gift are hidden on your own video — you can't repost or
        // tip yourself (matches the web's `mine` rule; the backend also 400s).
        if (!isMine) ...[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onRepostTap,
            child: _RailButton(
              // Arrows are strokes by nature — sized up a touch so its weight
              // matches the solid glyphs around it.
              icon: Icons.repeat_rounded,
              color: video.isReposted ? AppColors.badge : Colors.white,
              count: video.counts.reposts,
              size: 33,
            ),
          ),
          const SizedBox(height: 16),
        ],
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onShareTap,
          // Web's share is a paper-plane (send), not a curved reply arrow.
          child: _RailButton(
            icon: Icons.send_rounded,
            color: Colors.white,
            count: video.counts.shares,
            size: 29,
          ),
        ),
        const SizedBox(height: 16),
        if (!isMine) ...[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onGiftTap,
            child: _RailButton(
              icon: Icons.redeem_rounded,
              color: Colors.white,
              count: video.giftCoins,
              size: 30,
            ),
          ),
          const SizedBox(height: 16),
        ],
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onMoreTap,
          child: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 27, shadows: _railShadows),
        ),
        // Spinning sound disc (design's `.sound-disc`) — shown only for a
        // shareable sound (has a soundId), matching the web; tapping opens the
        // sound's page.
        if (video.soundId != null) ...[
          const SizedBox(height: 14),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onSoundTap,
            child: _SoundDisc(thumbUrl: video.thumbUrl),
          ),
        ],
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

/// Two-layer shadow that makes a white glyph readable on ANY frame. The tight,
/// nearly-opaque layer draws an edge so the shape stays defined against bright
/// video (a single soft shadow let the old thin outlines wash out on pale
/// backgrounds); the wide, soft layer lifts it off the picture.
const _railShadows = <Shadow>[
  Shadow(color: Color(0x8C000000), blurRadius: 3),
  Shadow(color: Color(0x59000000), blurRadius: 12, offset: Offset(0, 2)),
];

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.color,
    required this.count,
    this.size = 31,
  });
  final IconData icon;
  final Color color;
  final int count;

  /// Per-glyph optical size. Material icons don't fill their box equally — a
  /// solid heart reads bigger than a paper plane at the same nominal size — so
  /// each one is nudged to look the same weight in the rail.
  final double size;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: size, shadows: _railShadows),
        const SizedBox(height: 5),
        Text(
          _formatCount(count),
          style: AppTypography.mono(fontSize: 12, color: Colors.white).copyWith(
            fontWeight: FontWeight.w600,
            shadows: _railShadows,
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
