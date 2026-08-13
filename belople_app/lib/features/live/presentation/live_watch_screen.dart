import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/top_toast.dart';
import '../../feed/data/feed_repository.dart';
import '../../../core/widgets/snappy_page_physics.dart';
import '../application/active_lives_controller.dart';
import '../data/live_repository.dart';
import 'live_gift_sheet.dart';
import 'live_overlay.dart';

/// Watching lives.
///
/// Once you are in, swiping moves you between LIVES — not back into the videos
/// you came from. That is the owner's rule: you tapped into Live, so you are
/// in Live until you leave it, and the way out is the ✕ or back, not a swipe.
/// The list is the same one discovery serves, already ordered three-from-home
/// to one-from-away, so scrolling here is scrolling that order.
///
/// Only the page you are on holds a player. Every minute of a live is billed
/// per viewer, so pre-warming the next one would be paying its broadcaster for
/// an audience that has not arrived.
class LiveWatchScreen extends ConsumerStatefulWidget {
  const LiveWatchScreen({super.key, required this.sessionId});

  /// Where the swipe starts. The rest of the run comes from the active list.
  final String sessionId;

  @override
  ConsumerState<LiveWatchScreen> createState() => _LiveWatchScreenState();
}

class _LiveWatchScreenState extends ConsumerState<LiveWatchScreen> {
  PageController? _pager;
  int _page = 0;

  /// Frozen at the moment of entry. The rail refreshes every 20 seconds, and a
  /// list that reorders under a finger mid-swipe would land you on a different
  /// live than the one you were swiping towards.
  List<LiveSession>? _run;

  @override
  Widget build(BuildContext context) {
    final run = _run ??= _initialRun();
    if (run.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _LiveGone(message: 'That live has ended', onClose: () => context.pop()),
      );
    }
    _pager ??= PageController(initialPage: _page);

    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        controller: _pager,
        scrollDirection: Axis.vertical,
        // The same feel as the feed, from the same class — swiping between
        // lives and swiping between videos are one gesture and must not differ.
        physics: const SnappyPageScrollPhysics(),
        onPageChanged: (i) => setState(() => _page = i),
        itemCount: run.length,
        itemBuilder: (context, i) => _LivePage(
          key: ValueKey(run[i].id),
          sessionId: run[i].id,
          // The name and the face are already known — discovery handed them
          // over with the card that was tapped. Drawing them straight away is
          // the difference between opening a live and watching an anonymous
          // grey placeholder turn into a person a second later.
          seed: run[i],
          isActive: i == _page,
        ),
      ),
    );
  }

  /// The live that was tapped, then everything after it, then everything
  /// before — so a swipe down always continues rather than dead-ending on the
  /// one you happened to open.
  List<LiveSession> _initialRun() {
    final all = ref.read(activeLivesProvider).valueOrNull ?? const <LiveSession>[];
    final at = all.indexWhere((s) => s.id == widget.sessionId);
    if (at < 0) {
      // Opened from somewhere the rail hasn't caught up with (a link, a
      // notification). One live is still a run of one.
      return [
        LiveSession(
          id: widget.sessionId,
          status: 'live',
          creator: const LiveCreator(id: '', username: ''),
        ),
      ];
    }
    _page = at;
    return all;
  }

  @override
  void dispose() {
    _pager?.dispose();
    super.dispose();
  }
}

/// One live inside the pager: the picture, and everything over it.
class _LivePage extends ConsumerStatefulWidget {
  const _LivePage({
    super.key,
    required this.sessionId,
    required this.isActive,
    this.seed,
  });

  final String sessionId;
  final bool isActive;

  /// What discovery already knew: the creator, the title, the headcount. Used
  /// to paint the screen on the first frame; the fetch that follows only fills
  /// in what discovery does not carry (the playback URL, whether you follow).
  final LiveSession? seed;

  @override
  ConsumerState<_LivePage> createState() => _LivePageState();
}

class _LivePageState extends ConsumerState<_LivePage> {
  VideoPlayerController? _player;
  late LiveSession? _session = widget.seed;
  String? _error;
  bool _ended = false;
  bool _following = false;

  Timer? _poll;
  Timer? _reactFlush;
  int _since = 0;
  late int _viewers = widget.seed?.viewerCount ?? 0;
  int _pendingReacts = 0;
  final List<LiveComment> _comments = [];

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _open();
  }

  @override
  void didUpdateWidget(_LivePage old) {
    super.didUpdateWidget(old);
    // Swiped onto: start. Swiped away from: stop everything, including the
    // stream. A live left running behind another one is a viewer its
    // broadcaster is paying for and nobody is watching.
    if (widget.isActive && !old.isActive) _open();
    if (!widget.isActive && old.isActive) _close();
  }

  /// Tears down without ending anything: the session belongs to its creator,
  /// and swiping past it only means this phone stopped watching.
  void _close() {
    _poll?.cancel();
    _reactFlush?.cancel();
    if (_pendingReacts > 0) unawaited(_flushReacts());
    final p = _player;
    _player = null;
    p?.dispose();
    if (mounted) setState(() {});
  }

  Future<void> _open() async {
    try {
      final repo = ref.read(liveRepositoryProvider);
      final s = await repo.session(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _session = s;
        _viewers = s.viewerCount;
        _following = s.following;
      });

      if (!s.isLive || s.playbackUrl == null) {
        setState(() => _ended = true);
        return;
      }

      final player = VideoPlayerController.networkUrl(Uri.parse(s.playbackUrl!));
      await player.initialize();
      await player.play();
      if (!mounted) {
        player.dispose();
        return;
      }
      setState(() => _player = player);

      // Announce yourself once, so the room sees you arrive. Best effort — an
      // arrival nobody saw is not a reason to fail to watch.
      unawaited(repo.join(widget.sessionId).catchError((e) {
        debugPrint('[BLLIVE] join line failed: $e');
      }));

      _poll = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
      // Reactions are sent in batches, not per tap. Taps arrive in bursts of
      // ten and the count is approximate by design; a request each would be
      // the most expensive thing on the screen.
      _reactFlush = Timer.periodic(const Duration(seconds: 2), (_) => _flushReacts());
    } catch (e) {
      debugPrint('[BLLIVE] opening the live failed: $e');
      if (mounted) setState(() => _error = "Couldn't open this live — it may have ended");
    }
  }

  Future<void> _tick() async {
    try {
      final t = await ref.read(liveRepositoryProvider).tick(widget.sessionId, since: _since);
      if (!mounted) return;
      setState(() {
        _viewers = t.viewerCount;
        _since = t.since;
        _comments.addAll(t.comments);
        if (_comments.length > 60) _comments.removeRange(0, _comments.length - 60);
      });
      // The creator stopped, or their limit was reached. Either way there is
      // nothing left to play and nothing to go back to.
      if (t.ended) _finish();
    } catch (e) {
      // The video is a separate connection and is probably still fine, so a
      // dropped poll stays off the screen — but not out of the log.
      debugPrint('[BLLIVE] poll failed: $e');
    }
  }

  void _finish() {
    if (_ended) return;
    _poll?.cancel();
    _reactFlush?.cancel();
    _player?.pause();
    setState(() => _ended = true);
  }

  Future<void> _flushReacts() async {
    final n = _pendingReacts;
    if (n == 0) return;
    _pendingReacts = 0;
    try {
      await ref.read(liveRepositoryProvider).react(widget.sessionId, n);
    } catch (e) {
      debugPrint('[BLLIVE] sending $n reactions failed: $e');
    }
  }

  Future<void> _send(String text) async {
    try {
      await ref.read(liveRepositoryProvider).comment(widget.sessionId, text);
      // No local echo: the next poll is 3 seconds away at most and brings the
      // real row back with its id. Echoing meant every comment appeared twice
      // for one tick.
    } catch (e) {
      debugPrint('[BLLIVE] sending a comment failed: $e');
      if (mounted) showTopToast(context, "Couldn't send that — try again");
    }
  }

  Future<void> _follow() async {
    final creator = _session?.creator;
    if (creator == null) return;
    // Optimistic: the button is the whole interaction and it must not wait on
    // the network to look like it worked.
    setState(() => _following = true);
    try {
      final r = await ref.read(feedRepositoryProvider).setFollowing(creator.id, true);
      if (!mounted) return;
      // A private account files a request instead — saying "following" then
      // would be a lie.
      if (!r.following && r.requested) {
        setState(() => _following = false);
        showTopToast(context, 'Follow request sent');
      }
    } catch (e) {
      debugPrint('[BLLIVE] follow failed: $e');
      if (mounted) {
        setState(() => _following = false);
        showTopToast(context, "Couldn't follow — try again");
      }
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _reactFlush?.cancel();
    // Anything the finger already tapped still counts.
    if (_pendingReacts > 0) unawaited(_flushReacts());
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return Scaffold(
      backgroundColor: Colors.black,
      body: _error != null
          ? _LiveGone(message: _error!, onClose: () => context.pop())
          : _ended
              ? _LiveGone(
                  message: '${_session?.creator.name ?? 'This live'} has ended',
                  onClose: () => context.pop())
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    if (player != null && player.value.isInitialized)
                      // Letterboxed, not cropped. One of the streams read off
                      // the reference was a landscape screen-share on black,
                      // and BoxFit.cover would have thrown most of it away.
                      Center(
                        child: AspectRatio(
                          aspectRatio: player.value.aspectRatio,
                          child: VideoPlayer(player),
                        ),
                      )
                    else
                      const Center(child: CircularProgressIndicator(color: Colors.white)),

                    LiveOverlay(
                      creator: _session?.creator,
                      title: _session?.title,
                      viewers: _viewers,
                      comments: _comments,
                      connecting: player == null,
                      following: _following,
                      onFollow: _follow,
                      onSend: _send,
                      // Counted locally and flushed in batches; the heart is
                      // meant to feel instant, not to be exact.
                      onReact: () => _pendingReacts++,
                      onGift: () => showLiveGiftSheet(context, sessionId: widget.sessionId),
                      onViewProfile: () {
                        final u = _session?.creator.username;
                        if (u != null && u.isNotEmpty) context.push('/profile/$u');
                      },
                      onClose: () => context.pop(),
                    ),
                  ],
                ),
    );
  }
}

class _LiveGone extends StatelessWidget {
  const _LiveGone({required this.message, required this.onClose});
  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.podcasts, color: Colors.white38, size: 46),
              const SizedBox(height: 16),
              Text(message,
                  textAlign: TextAlign.center,
                  style: AppTypography.sans(
                      fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
              const SizedBox(height: 8),
              // Says the rule out loud rather than leaving someone hunting for
              // a replay button that does not exist.
              Text('Lives are not saved — you had to be there.',
                  textAlign: TextAlign.center,
                  style: AppTypography.sans(fontSize: 13.5, color: Colors.white54)),
              const SizedBox(height: 20),
              TextButton(
                onPressed: onClose,
                style: TextButton.styleFrom(foregroundColor: AppColors.accent),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );
}
