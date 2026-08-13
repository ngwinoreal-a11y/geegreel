import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../wallet/data/gift_repository.dart';
import '../data/live_repository.dart';

/// Everything that floats over a live picture, for both sides of it.
///
/// The arrangement is the one the owner pointed at on their own phone (see
/// docs/live-design.md): a dark pill top-left carrying the creator, the
/// headcount top-right, comments rising from the bottom over the video with no
/// panel behind them, and a bar under that.
///
/// Nothing here scrolls backwards. The comment strip only ever grows upward
/// and the oldest lines leave — which is the same promise the video makes.
class LiveOverlay extends StatelessWidget {
  const LiveOverlay({
    super.key,
    required this.viewers,
    required this.comments,
    required this.onClose,
    this.title,
    this.creator,
    this.isBroadcaster = false,
    this.connecting = false,
    this.clockLabel,
    this.following = false,
    this.onFollow,
    this.onSend,
    this.onReact,
    this.onGift,
  });

  final int viewers;
  final List<LiveComment> comments;
  final VoidCallback onClose;
  final String? title;
  final LiveCreator? creator;

  /// The creator sees their own elapsed time and no follow button; a viewer
  /// sees the creator and can follow them.
  final bool isBroadcaster;
  final bool connecting;
  final String? clockLabel;
  final bool following;
  final VoidCallback? onFollow;
  final void Function(String text)? onSend;
  final VoidCallback? onReact;

  /// Opens the gift picker. Gifts are the one place coins are SPENT in a live —
  /// the app never offers a way to buy them, which is the rule Play enforces
  /// and the reason the wallet's own top-up lives on the website.
  final VoidCallback? onGift;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(
              children: [
                // Expanded + Align, NOT Flexible + Spacer. A Spacer is an
                // Expanded(flex: 1), so it competed with the pill's Flexible
                // for the row and each got half — the pill overflowed its half
                // and Flutter drew the overflow stripes over the creator's name.
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _creatorPill(context),
                  ),
                ),
                const SizedBox(width: 8),
                _countPill(),
                const SizedBox(width: 8),
                _roundButton(Icons.close, onClose),
              ],
            ),
          ),
          if (title != null && title!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 60, 0),
              child: Text(
                title!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.sans(fontSize: 14, color: Colors.white)
                    .copyWith(shadows: const [Shadow(color: Colors.black87, blurRadius: 6)]),
              ),
            ),

          const Spacer(),

          if (connecting)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                      width: 15, height: 15,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Text('Connecting…',
                      style: AppTypography.sans(fontSize: 13.5, color: Colors.white)
                          .copyWith(shadows: const [Shadow(color: Colors.black87, blurRadius: 6)])),
                ],
              ),
            ),

          // Gifts get their own strip above the chat. They are the loudest
          // thing that happens in a room and they are over quickly — mixed
          // into the rising comments they would scroll away mid-cheer, and
          // left on screen they would bury it.
          _GiftBanners(comments: comments),
          _commentStream(),
          _bottomBar(context),
        ],
      ),
    );
  }

  Widget _creatorPill(BuildContext context) {
    final c = creator;
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (c != null)
            AppAvatar(
                imageUrl: c.avatarUrl == null ? null : mediaUrl(c.avatarUrl!),
                displayName: c.name,
                size: 34)
          else
            Container(
              width: 34, height: 34,
              decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
              child: const Icon(Icons.podcasts, size: 18, color: Colors.white),
            ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isBroadcaster ? 'You are live' : (c?.name ?? 'Live'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.sans(
                      fontSize: 14.5, fontWeight: FontWeight.w700, color: Colors.white),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.danger,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('LIVE',
                          style: AppTypography.sans(
                              fontSize: 10, fontWeight: FontWeight.w900, color: Colors.white)),
                    ),
                    if (clockLabel != null) ...[
                      const SizedBox(width: 6),
                      Text(clockLabel!,
                          style: AppTypography.sans(fontSize: 11.5, color: Colors.white70)),
                    ],
                  ],
                ),
              ],
            ),
          ),
          // A viewer can follow without leaving; the creator has nobody to
          // follow, so the slot is simply absent rather than disabled. It also
          // waits for the creator to load — a Follow button beside a blank name
          // is asking you to follow you-don't-know-who.
          if (!isBroadcaster && c != null && !following && onFollow != null) ...[
            const SizedBox(width: 10),
            GestureDetector(
              onTap: onFollow,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.danger,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text('Follow',
                    style: AppTypography.sans(
                        fontSize: 13, fontWeight: FontWeight.w800, color: Colors.white)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _countPill() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.remove_red_eye_outlined, size: 15, color: Colors.white),
            const SizedBox(width: 5),
            Text('$viewers',
                style: AppTypography.sans(
                    fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.white)),
          ],
        ),
      );

  Widget _roundButton(IconData icon, VoidCallback onTap) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 20, color: Colors.white),
        ),
      );

  /// Rises from the bottom, no background of its own, oldest at the top. Fixed
  /// height so it never pushes the bar around as lines arrive.
  Widget _commentStream() => SizedBox(
        height: 200,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(14, 0, 60, 8),
          // Newest at the bottom, and the list sits at the bottom by default —
          // which is where a live chat is always read from.
          reverse: true,
          itemCount: comments.length,
          itemBuilder: (context, i) => _line(comments[comments.length - 1 - i]),
        ),
      );

  Widget _line(LiveComment c) {
    final shadow = const [Shadow(color: Colors.black87, blurRadius: 6)];
    // Arrivals and reactions share the strip with what people type — they are
    // the room breathing, and pulling them into their own list would have made
    // three feeds out of one conversation.
    if (c.kind != 'comment') {
      // The banner above says it loudly and goes; this is the line that stays,
      // so the room can still see who gave what after the cheer has passed.
      final isGift = c.kind == 'gift';
      final icon = switch (c.kind) {
        'like' => Icons.favorite,
        'gift' => Icons.card_giftcard,
        _ => Icons.waving_hand,
      };
      final text = switch (c.kind) {
        'like' => '${c.user.name} liked the LIVE',
        'gift' => '${c.user.name} sent a gift',
        _ => '${c.user.name} joined',
      };
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 15, color: isGift ? AppColors.danger : Colors.white70),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.sans(
                        fontSize: 13, color: isGift ? Colors.white : Colors.white70)
                    .copyWith(shadows: shadow),
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAvatar(
              imageUrl: c.user.avatarUrl == null ? null : mediaUrl(c.user.avatarUrl!),
              displayName: c.user.name,
              size: 24),
          const SizedBox(width: 8),
          Expanded(
            child: RichText(
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(children: [
                TextSpan(
                  text: '${c.user.name}  ',
                  style: AppTypography.sans(fontSize: 13, color: Colors.white60)
                      .copyWith(shadows: shadow),
                ),
                TextSpan(
                  text: c.body,
                  style: AppTypography.sans(fontSize: 14, color: Colors.white)
                      .copyWith(shadows: shadow),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    if (isBroadcaster) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
        child: Row(
          children: [
            Expanded(
              child: Text('Your live is on',
                  style: AppTypography.sans(fontSize: 13, color: Colors.white70)
                      .copyWith(shadows: const [Shadow(color: Colors.black87, blurRadius: 6)])),
            ),
            GestureDetector(
              onTap: onClose,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                decoration: BoxDecoration(
                  color: AppColors.danger,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text('End live',
                    style: AppTypography.sans(
                        fontSize: 14.5, fontWeight: FontWeight.w800, color: Colors.white)),
              ),
            ),
          ],
        ),
      );
    }
    return _ViewerBar(onSend: onSend, onReact: onReact, onGift: onGift);
  }
}

/// Gifts, shown to the whole room and then gone.
///
/// Each one appears for [_hold] and leaves. Several can be up at once, because
/// several people gift at once and the point is that everybody sees who did —
/// their face, their name, what they sent and how many.
class _GiftBanners extends ConsumerStatefulWidget {
  const _GiftBanners({required this.comments});
  final List<LiveComment> comments;

  @override
  ConsumerState<_GiftBanners> createState() => _GiftBannersState();
}

class _GiftBannersState extends ConsumerState<_GiftBanners> {
  static const _hold = Duration(seconds: 5);

  /// Ids already put on screen. The poll hands back the same rows until they
  /// fall out of its window, and without this each one would be re-announced
  /// every three seconds.
  final _seen = <String>{};
  final _showing = <LiveComment>[];
  final _timers = <Timer>[];

  @override
  void didUpdateWidget(_GiftBanners old) {
    super.didUpdateWidget(old);
    _ingest();
  }

  @override
  void initState() {
    super.initState();
    _ingest();
  }

  void _ingest() {
    for (final c in widget.comments) {
      if (c.kind != 'gift' || _seen.contains(c.id)) continue;
      _seen.add(c.id);
      _showing.add(c);
      _timers.add(Timer(_hold, () {
        if (!mounted) return;
        setState(() => _showing.remove(c));
      }));
    }
    // Keeps the strip to what fits. A rush of gifts should look like a rush,
    // not push the chat off the screen.
    if (_showing.length > 3) _showing.removeRange(0, _showing.length - 3);
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_showing.isEmpty) return const SizedBox.shrink();
    final catalog = kGifts;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 60, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in _showing) _banner(c, catalog),
        ],
      ),
    );
  }

  Widget _banner(LiveComment c, List<Gift> catalog) {
    // The server writes "<giftKey>|<count>", so the room can be told what was
    // sent without a second request per gift.
    final parts = c.body.split('|');
    final key = parts.first;
    final count = parts.length > 1 ? int.tryParse(parts[1]) ?? 1 : 1;
    final gift = catalog.where((g) => g.key == key).firstOrNull;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 5, 12, 5),
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppAvatar(
              size: 26,
              imageUrl: c.user.avatarUrl == null ? null : mediaUrl(c.user.avatarUrl!),
              displayName: c.user.name,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '${c.user.name} sent ${gift?.name ?? 'a gift'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.sans(
                    fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
              ),
            ),
            const SizedBox(width: 8),
            Text(gift?.emoji ?? '🎁', style: const TextStyle(fontSize: 19)),
            if (count > 1) ...[
              const SizedBox(width: 6),
              Text('x$count',
                  style: AppTypography.sans(
                      fontSize: 15, fontWeight: FontWeight.w900, color: Colors.white)),
            ],
          ],
        ),
      ),
    );
  }
}

/// The viewer's bar: say something, or react. Kept as its own stateful widget
/// so typing doesn't rebuild the video and the comment strip on every keypress.
class _ViewerBar extends StatefulWidget {
  const _ViewerBar({this.onSend, this.onReact, this.onGift});
  final void Function(String text)? onSend;
  final VoidCallback? onReact;
  final VoidCallback? onGift;

  @override
  State<_ViewerBar> createState() => _ViewerBarState();
}

class _ViewerBarState extends State<_ViewerBar> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    widget.onSend?.call(text);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
            12, 6, 12, 12 + MediaQuery.of(context).viewInsets.bottom),
        child: Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: TextField(
                  controller: _controller,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  style: AppTypography.sans(fontSize: 14.5, color: Colors.white),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 13),
                    hintText: 'Type…',
                    hintStyle: AppTypography.sans(fontSize: 14.5, color: Colors.white54),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onGift,
              child: Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.card_giftcard, color: Colors.white, size: 22),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              // No await, no spinner, no confirmation: the tap is the whole
              // interaction and the count is approximate anyway.
              onTap: widget.onReact,
              child: Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.favorite, color: AppColors.danger, size: 22),
              ),
            ),
          ],
        ),
      );
}
