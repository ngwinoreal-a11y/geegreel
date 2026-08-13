import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../data/live_repository.dart';
import 'live_avatar.dart';

/// A live, sitting in the feed as one more thing you scroll onto.
///
/// This is the arrangement the owner pointed at (YouTube's, in
/// docs/live-design.md): the broadcast itself plays underneath as a preview,
/// "Tap to watch live" across the middle, and the creator, title and headcount
/// along the bottom. You do not go to a Live section — you scroll into one.
///
/// The preview plays **with sound**, like every other page of this feed. A
/// silent live looks like a photograph of one: you cannot tell whether anything
/// is happening, and half of what makes a live worth opening is hearing that
/// someone is mid-sentence. It stops the moment you swipe past.
class LiveFeedCard extends ConsumerStatefulWidget {
  const LiveFeedCard({super.key, required this.session, required this.isActive});

  final LiveSession session;

  /// Only the page actually on screen holds a player. Everything about a live
  /// costs the broadcaster money by the minute per viewer, so a card two swipes
  /// away must not be pulling the stream.
  final bool isActive;

  @override
  ConsumerState<LiveFeedCard> createState() => _LiveFeedCardState();
}

class _LiveFeedCardState extends ConsumerState<LiveFeedCard> {
  VideoPlayerController? _player;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _attach();
  }

  @override
  void didUpdateWidget(LiveFeedCard old) {
    super.didUpdateWidget(old);
    if (widget.isActive && _player == null) _attach();
    if (!widget.isActive && _player != null) _detach();
  }

  Future<void> _attach() async {
    final url = widget.session.playbackUrl;
    if (url == null) return;
    try {
      final p = VideoPlayerController.networkUrl(Uri.parse(url));
      await p.initialize();
      await p.play();
      if (!mounted) {
        p.dispose();
        return;
      }
      setState(() => _player = p);
    } catch (e) {
      // The card still works without it — it falls back to the creator's
      // avatar and the words, which is enough to decide to tap.
      debugPrint('[BLLIVE] preview for ${widget.session.id} failed: $e');
    }
  }

  void _detach() {
    final p = _player;
    _player = null;
    p?.dispose();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final p = _player;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.push('/live/${s.id}'),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (p != null && p.value.isInitialized)
            // Letterboxed rather than cropped — a live can be landscape, and
            // cover would throw most of it away.
            Center(
              child: AspectRatio(aspectRatio: p.value.aspectRatio, child: VideoPlayer(p)),
            )
          else
            Center(
              child: AppAvatar(
                size: 96,
                imageUrl: s.creator.avatarUrl == null ? null : mediaUrl(s.creator.avatarUrl!),
                displayName: s.creator.name,
              ),
            ),

          // Keeps the words legible over whatever the broadcast happens to be
          // pointing at.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.center,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
              ),
            ),
          ),

          Align(
            alignment: const Alignment(0, 0.42),
            child: Text('(( Tap to watch live ))',
                style: AppTypography.sans(
                        fontSize: 19, fontWeight: FontWeight.w800, color: Colors.white)
                    .copyWith(shadows: const [Shadow(color: Colors.black, blurRadius: 8)])),
          ),

          // 116, the same inset the video slides use, because the floating
          // nav pill sits over the bottom of every feed page. At 26 the title
          // and the headcount were behind it.
          Positioned(
            left: 16, right: 16, bottom: 116,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    // The same widget the feed puts on a live creator's videos,
                    // so the two cannot drift apart — which is exactly what the
                    // owner spotted when they were built separately.
                    LiveAvatar(
                      size: 44,
                      imageUrl:
                          s.creator.avatarUrl == null ? null : mediaUrl(s.creator.avatarUrl!),
                      displayName: s.creator.name,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('@${s.creator.username}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.sans(
                              fontSize: 15.5, fontWeight: FontWeight.w700, color: Colors.white)),
                    ),
                  ],
                ),
                if ((s.title ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(s.title!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.sans(fontSize: 14.5, color: Colors.white)),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.person_outline, size: 17, color: Colors.white),
                    const SizedBox(width: 6),
                    Text('${s.viewerCount}',
                        style: AppTypography.sans(
                            fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
