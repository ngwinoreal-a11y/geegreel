import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/brand_refresh.dart';
import '../../../core/widgets/brand_wordmark.dart';
import '../../../core/widgets/linkified_text.dart';
import '../../../core/widgets/skeleton.dart';
import '../../auth/application/auth_controller.dart';
import '../../feed/data/feed_repository.dart';
import '../../feed/data/video_model.dart';
import '../application/public_feed_controller.dart';
import '../data/post_model.dart';
import 'post_comments_sheet.dart';

/// Compact "time ago" for a post's age — matches the web's "4d", "3h", "just
/// now" style shown next to the author.
String _timeAgo(DateTime when) {
  final d = DateTime.now().difference(when);
  if (d.inSeconds < 60) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  if (d.inDays < 30) return '${(d.inDays / 7).floor()}w';
  if (d.inDays < 365) return '${(d.inDays / 30).floor()}mo';
  return '${(d.inDays / 365).floor()}y';
}

// ---------------------------------------------------------------------------
// Public's own palette. This page is WHITE while the rest of the app is dark,
// so every colour a widget here uses is named up front rather than reached for
// ad hoc — reading `AppColors.text` on a white page is how text has ended up
// invisible three times.
// ---------------------------------------------------------------------------

/// Body text, names, counts, action icons.
const _ink = AppColors.onChrome; // #111

/// Timestamps, "Following", empty states. 5.1:1 on white — onChromeMuted only
/// reaches 3.4:1 and is for dark chrome, not for a white page.
const _inkMuted = AppColors.onSheetMuted;

/// Fill behind a text-only post.
const _fill = AppColors.sheetFill;

/// Ports public.js's mountPublic(): an Instagram-like photo feed with one
/// video spliced in after every 3 photo posts (drawn from the For You feed),
/// and one photo/text ad woven in near the top.
class PublicFeedScreen extends ConsumerStatefulWidget {
  const PublicFeedScreen({super.key});

  @override
  ConsumerState<PublicFeedScreen> createState() => _PublicFeedScreenState();
}

/// One video after every N photo posts (matches public.js's postsSinceVideo).
const _videoEvery = 3;

/// How many posts down the ad sits. Not first — an ad as the very first thing
/// on the page reads as the page being an ad.
const _adAfter = 2;

class _PublicFeedScreenState extends ConsumerState<PublicFeedScreen> {
  late final ScrollController _scrollController;

  // Videos to splice in, drawn lazily from the For You feed. Kept in the
  // screen (not the posts controller) so the photo feed's caching stays
  // untouched — mirrors public.js's separate videoPool/videoCursor state.
  final List<VideoModel> _videoPool = [];
  String? _videoCursor;
  bool _videoDone = false;
  bool _videoLoading = false;

  /// Sound is a decision about the FEED, not about one card: unmuting a video
  /// means "I want to hear this feed", so every later video keeps playing with
  /// sound, and muting again silences them all. Held in the screen's own State
  /// so it lasts exactly as long as Public is open — leaving the page drops it
  /// and the feed starts muted again, the way the user expects.
  bool _soundOn = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()..addListener(_onScroll);
    _loadVideos();
  }

  Future<void> _loadVideos() async {
    if (_videoLoading || _videoDone) return;
    _videoLoading = true;
    try {
      final page = await ref
          .read(feedRepositoryProvider)
          .fetchFeed(tab: 'foryou', cursor: _videoCursor, limit: 12);
      if (!mounted) return;
      setState(() {
        _videoCursor = page.nextCursor;
        if (page.nextCursor == null) _videoDone = true;
        _videoPool.addAll(page.videos.where((v) => !v.isAd));
      });
    } catch (_) {
      _videoDone = true;
    } finally {
      _videoLoading = false;
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >
        _scrollController.position.maxScrollExtent - 800) {
      ref.read(publicFeedControllerProvider.notifier).loadMore();
    }
  }

  /// Interleaves posts, pooled videos and the one ad: post, post, ad, post,
  /// video, post… A video slot with no video left (pool not yet refilled) is
  /// simply skipped rather than blocking the feed.
  List<_FeedItem> _interleave(List<PostModel> posts, VideoModel? ad) {
    final items = <_FeedItem>[];
    var videoIdx = 0;
    for (var i = 0; i < posts.length; i++) {
      items.add(_PostItem(posts[i]));
      if (ad != null && i + 1 == _adAfter) items.add(_AdItem(ad));
      if ((i + 1) % _videoEvery == 0) {
        if (videoIdx < _videoPool.length) {
          items.add(_VideoItem(_videoPool[videoIdx]));
          videoIdx++;
        } else if (!_videoDone) {
          // Ran dry mid-feed — pull the next page for later frames.
          _loadVideos();
        }
      }
    }
    return items;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Reaching for the phone's volume rocker while a muted preview is playing
  /// means "let me hear this" — so it turns the feed's sound on, the way the
  /// other photo/video feeds people use behave. The event is deliberately NOT
  /// consumed: Android must still change the actual system volume.
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    final k = event.logicalKey;
    if (event is KeyDownEvent &&
        (k == LogicalKeyboardKey.audioVolumeUp || k == LogicalKeyboardKey.audioVolumeDown) &&
        !_soundOn) {
      setState(() => _soundOn = true);
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(publicFeedControllerProvider);

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        // White, like Instagram and like Public's own web page. It was dark for
        // one release and read as heavy — photos need something bright to sit
        // against, and the app already has a dark Shorts feed to contrast with.
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          // The back arrow and any overflow icon, on white.
          foregroundColor: _ink,
          // A white bar needs DARK status-bar icons above it, or the clock and
          // battery disappear into it.
          systemOverlayStyle: SystemUiOverlayStyle.dark,
          elevation: 0,
          centerTitle: true,
          title: const BrandWordmark(),
        ),
        body: feedAsync.when(
          loading: () => ListView.builder(
            itemCount: 3,
            itemBuilder: (context, i) => const _PostSkeleton(),
          ),
          error: (e, _) => Center(
            child: Text("Couldn't load posts", style: AppTypography.sans(color: _inkMuted)),
          ),
          data: (state) {
            if (state.posts.isEmpty) {
              return Center(child: Text('No posts yet', style: AppTypography.sans(color: _inkMuted)));
            }
            final items = _interleave(state.posts, state.ad);
            return BrandRefresh(
              onRefresh: () async {
                ref.invalidate(publicFeedControllerProvider);
                await ref.read(publicFeedControllerProvider.future);
              },
              // No rule between posts: the media is the card, the gap is the
              // separator. A hairline across a white feed reads as clutter.
              child: ListView.builder(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final item = items[i];
                  if (item is _VideoItem) {
                    return _VideoCard(
                      video: item.video,
                      soundOn: _soundOn,
                      onSoundToggle: () => setState(() => _soundOn = !_soundOn),
                    );
                  }
                  if (item is _AdItem) return _AdCard(ad: item.ad);
                  final post = (item as _PostItem).post;
                  return _PostCard(
                    post: post,
                    onLikeTap: () =>
                        ref.read(publicFeedControllerProvider.notifier).toggleLike(post.id),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The overlaid author header
// ---------------------------------------------------------------------------

/// Author row drawn ON TOP of the media, Instagram-style, instead of in its own
/// band above it. That band cost ~58px of height on every single card — on a
/// phone it pushed the picture down far enough that you saw less of it than of
/// the chrome around it. Over the media it costs nothing.
///
/// White ink with a scrim behind it: over an arbitrary photo, a colour is only
/// legible if it brings its own background, and a top-down black gradient is
/// the least intrusive one that works over both a bright sky and a dark room.
class _MediaHeader extends StatelessWidget {
  const _MediaHeader({
    required this.displayName,
    this.avatarUrl,
    this.subtitle,
    this.verified = false,
    this.onTapAuthor,
    this.trailing,
  });

  final String displayName;
  final String? avatarUrl;

  /// The small line after the name — a timestamp, or "Sponsored".
  final String? subtitle;
  final bool verified;
  final VoidCallback? onTapAuthor;

  /// Follow, or nothing.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        // The scrim must never eat a tap meant for the media beneath it; the
        // row inside it is re-enabled below.
        ignoring: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 26),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x8C000000), Color(0x00000000)],
            ),
          ),
          child: Row(
            children: [
              GestureDetector(
                onTap: onTapAuthor,
                child: AppAvatar(size: 32, ring: true, imageUrl: avatarUrl, displayName: displayName),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: GestureDetector(
                  onTap: onTapAuthor,
                  behavior: HitTestBehavior.opaque,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(displayName,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.sans(
                                    fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
                          ),
                          if (verified) ...[
                            const SizedBox(width: 4),
                            const Icon(Icons.verified, color: Colors.white, size: 14),
                          ],
                        ],
                      ),
                      if (subtitle != null)
                        Text(subtitle!,
                            style: AppTypography.sans(
                                fontSize: 11.5, color: Colors.white.withValues(alpha: 0.82))),
                    ],
                  ),
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

/// The Follow pill as it appears over media — outlined white, so it reads as a
/// control on any picture without a solid block of colour.
class _FollowOverMedia extends StatelessWidget {
  const _FollowOverMedia({required this.following, required this.onTap});
  final bool following;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 1.2),
          borderRadius: BorderRadius.circular(8),
          color: Colors.black.withValues(alpha: 0.22),
        ),
        child: Text(following ? 'Following' : 'Follow',
            style: AppTypography.sans(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white)),
      ),
    );
  }
}

/// The like / comment / share row and caption that sit BELOW the media, on the
/// white page — shared by posts, videos and ads so the three never drift apart.
class _CardFooter extends StatelessWidget {
  const _CardFooter({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.publicPostPadding, 11, AppSpacing.publicPostPadding, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({required this.icon, required this.count, required this.onTap, this.color});
  final IconData icon;
  final int count;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Opaque so the gaps in the row don't swallow taps — without it the like
      // feels dead unless you hit the glyph exactly.
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Row(children: [
        Icon(icon, color: color ?? _ink, size: 25),
        const SizedBox(width: 7),
        Text('$count', style: AppTypography.mono(fontSize: 15, color: _ink)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------

/// Even air below each card; the gap alone separates one post from the next.
const _cardPadding = EdgeInsets.only(top: 4, bottom: 26);

class _PostCard extends ConsumerWidget {
  const _PostCard({required this.post, required this.onLikeTap});
  final PostModel post;
  final VoidCallback onLikeTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authControllerProvider).valueOrNull;
    final isMine = me != null && me.id == post.user.id;
    final hasImage = post.imageUrl != null;

    void openAuthor() => context.push('/profile/${post.user.username}');
    void toggleFollow() {
      if (!ref.read(isLoggedInProvider)) {
        context.push('/login');
        return;
      }
      ref.read(publicFeedControllerProvider.notifier).toggleFollow(post.user.id, post.following);
    }

    return Padding(
      padding: _cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasImage)
            Stack(
              children: [
                // With real dimensions the box matches the photo, so `cover`
                // fills it exactly and there is nothing left over to show as
                // white. With unknown dimensions we DON'T impose a shape at
                // all — the image takes its own height once decoded, which is
                // what stops a short photo sitting in a tall empty card.
                post.hasKnownSize
                    ? AspectRatio(
                        aspectRatio: post.aspectRatio,
                        child: CachedNetworkImage(
                          imageUrl: mediaUrl(post.imageUrl!),
                          fit: BoxFit.cover,
                          width: double.infinity,
                        ),
                      )
                    : CachedNetworkImage(
                        imageUrl: mediaUrl(post.imageUrl!),
                        fit: BoxFit.fitWidth,
                        width: double.infinity,
                      ),
                _MediaHeader(
                  displayName: post.user.displayName,
                  avatarUrl: post.user.avatarUrl != null ? mediaUrl(post.user.avatarUrl!) : null,
                  subtitle: _timeAgo(post.createdAt),
                  verified: post.user.verified,
                  onTapAuthor: openAuthor,
                  trailing: isMine
                      ? null
                      : _FollowOverMedia(following: post.following, onTap: toggleFollow),
                ),
              ],
            )
          else
            // A text-only post has no media to lay a header over, so the header
            // stays a normal row — in dark ink, on the white page.
            _TextPostBody(
              post: post,
              isMine: isMine,
              onTapAuthor: openAuthor,
              onToggleFollow: toggleFollow,
            ),
          _CardFooter(children: [
            Row(children: [
              _ActionIcon(
                icon: post.liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                color: post.liked ? AppColors.badge : _ink,
                count: post.likes,
                onTap: () {
                  if (!ref.read(isLoggedInProvider)) {
                    context.push('/login');
                  } else {
                    onLikeTap();
                  }
                },
              ),
              const SizedBox(width: 20),
              _ActionIcon(
                icon: Icons.mode_comment_outlined,
                count: post.comments,
                onTap: () => showPostCommentsSheet(context, postId: post.id),
              ),
              const SizedBox(width: 20),
              _ActionIcon(
                icon: Icons.send_rounded,
                count: post.shares,
                onTap: () async {
                  // The real system share sheet with a link to the post
                  // (matches public.js's share()), then bump the count.
                  await Share.share('$kApiBaseUrl/p/${post.id}', subject: 'Belople post');
                  ref.read(publicFeedControllerProvider.notifier).registerShare(post.id);
                },
              ),
            ]),
            // The caption goes under the picture it belongs to. On a text post
            // the words ARE the post and are already drawn above.
            if (hasImage && post.content.isNotEmpty) ...[
              const SizedBox(height: 9),
              LinkifiedText(text: post.content, style: AppTypography.sans(fontSize: 15, color: _ink)),
            ],
          ]),
        ],
      ),
    );
  }
}

/// The header + body of a post with no photo: nothing to overlay, so this is
/// the one place the author line keeps its own row.
class _TextPostBody extends StatelessWidget {
  const _TextPostBody({
    required this.post,
    required this.isMine,
    required this.onTapAuthor,
    required this.onToggleFollow,
  });
  final PostModel post;
  final bool isMine;
  final VoidCallback onTapAuthor;
  final VoidCallback onToggleFollow;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.publicPostPadding, 6, AppSpacing.publicPostPadding, 10),
          child: Row(
            children: [
              GestureDetector(
                onTap: onTapAuthor,
                child: AppAvatar(
                  size: 32,
                  ring: true,
                  imageUrl: post.user.avatarUrl != null ? mediaUrl(post.user.avatarUrl!) : null,
                  displayName: post.user.displayName,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: GestureDetector(
                  onTap: onTapAuthor,
                  behavior: HitTestBehavior.opaque,
                  child: Row(children: [
                    Flexible(
                      child: Text(post.user.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.sans(
                              fontSize: 14, fontWeight: FontWeight.w700, color: _ink)),
                    ),
                    // Blue tick only for the official/admin (Belople) account.
                    if (post.user.verified) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.verified, color: AppColors.verified, size: 14),
                    ],
                    const SizedBox(width: 8),
                    Text(_timeAgo(post.createdAt),
                        style: AppTypography.sans(fontSize: 12, color: _inkMuted)),
                  ]),
                ),
              ),
              if (!isMine)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onToggleFollow,
                  child: Text(
                    post.following ? 'Following' : 'Follow',
                    style: AppTypography.sans(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: post.following ? _inkMuted : AppColors.verified,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (post.content.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.publicPostPadding),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: _fill, borderRadius: BorderRadius.circular(14)),
              child: LinkifiedText(
                  text: post.content,
                  style: AppTypography.sans(fontSize: 15, fontWeight: FontWeight.w700, color: _ink)),
            ),
          ),
      ],
    );
  }
}

/// A row in the interleaved public feed: a photo post, a spliced-in video from
/// the For You feed, or the one ad.
sealed class _FeedItem {
  const _FeedItem();
}

class _PostItem extends _FeedItem {
  const _PostItem(this.post);
  final PostModel post;
}

class _VideoItem extends _FeedItem {
  const _VideoItem(this.video);
  final VideoModel video;
}

class _AdItem extends _FeedItem {
  const _AdItem(this.ad);
  final VideoModel ad;
}

// ---------------------------------------------------------------------------
// Ad
// ---------------------------------------------------------------------------

/// A photo (or text) ad, drawn as a post so it belongs on the page instead of
/// interrupting it — sponsor where the author goes, "Sponsored" where the
/// timestamp goes, and one call-to-action bar under the picture.
///
/// Video ads are NOT shown here: they go to Shorts, where a full-screen
/// vertical video is what the whole feed already is.
class _AdCard extends ConsumerStatefulWidget {
  const _AdCard({required this.ad});
  final VideoModel ad;

  @override
  ConsumerState<_AdCard> createState() => _AdCardState();
}

class _AdCardState extends ConsumerState<_AdCard> {
  /// An impression is counted once per card, the first time it is actually on
  /// screen — not on build, which happens while it is still below the fold.
  bool _counted = false;

  void _onVisibility(VisibilityInfo info) {
    if (_counted || info.visibleFraction < 0.5) return;
    _counted = true;
    final id = widget.ad.adId ?? widget.ad.id;
    // Best-effort: a missed impression must never break the feed.
    unawaited(ref.read(feedRepositoryProvider).recordAdView(id).catchError((_) {}));
  }

  Future<void> _openLink() async {
    final url = widget.ad.linkUrl;
    if (url == null || url.isEmpty) return;
    final id = widget.ad.adId ?? widget.ad.id;
    unawaited(ref.read(feedRepositoryProvider).recordAdClick(id).catchError((_) {}));
    final uri = Uri.tryParse(url);
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final ad = widget.ad;
    final media = ad.thumbUrl ?? (ad.videoUrl.isNotEmpty ? ad.videoUrl : null);
    return VisibilityDetector(
      key: Key('pubad-${ad.id}'),
      onVisibilityChanged: _onVisibility,
      child: Padding(
        padding: _cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: _openLink,
              child: Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: media == null
                        ? Container(color: _fill)
                        : CachedNetworkImage(
                            imageUrl: mediaUrl(media),
                            fit: BoxFit.cover,
                            width: double.infinity,
                          ),
                  ),
                  _MediaHeader(
                    displayName: ad.sponsorName ?? 'Belople',
                    avatarUrl: ad.user.avatarUrl != null ? mediaUrl(ad.user.avatarUrl!) : null,
                    // Says what it is, in the place a timestamp would be. An ad
                    // that doesn't announce itself isn't one you can trust.
                    subtitle: 'Sponsored',
                  ),
                ],
              ),
            ),
            // The call to action, full width under the picture — the shape a
            // sponsored post takes everywhere, so it needs no explaining.
            if ((ad.linkUrl ?? '').isNotEmpty)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _openLink,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  color: AppColors.accent,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(ad.ctaText ?? 'Learn more',
                          style: AppTypography.sans(
                              fontSize: 14.5, fontWeight: FontWeight.w700, color: AppColors.onAccent)),
                      const SizedBox(width: 6),
                      // onAccent, not white: the accent is a LIGHT amber and
                      // white on it is unreadable.
                      const Icon(Icons.arrow_forward_rounded, size: 17, color: AppColors.onAccent),
                    ],
                  ),
                ),
              ),
            if (ad.caption.isNotEmpty)
              _CardFooter(children: [
                LinkifiedText(text: ad.caption, style: AppTypography.sans(fontSize: 15, color: _ink)),
              ]),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Video
// ---------------------------------------------------------------------------

/// How long a video has to hold the screen before we offer the way into the
/// full Shorts feed.
const _watchMoreAfter = Duration(seconds: 8);

/// A spliced feed video that autoplays muted while on screen (Instagram style)
/// and pauses the instant it scrolls away — controlled by a VisibilityDetector
/// so only the visible one is ever decoding. A speaker button toggles sound;
/// tapping the video opens the full vertical player.
class _VideoCard extends StatefulWidget {
  const _VideoCard({
    required this.video,
    required this.soundOn,
    required this.onSoundToggle,
  });
  final VideoModel video;

  /// Feed-wide sound setting (see _PublicFeedScreenState._soundOn).
  final bool soundOn;
  final VoidCallback onSoundToggle;

  @override
  State<_VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<_VideoCard> {
  VideoPlayerController? _controller;
  bool _visible = false;
  bool _initializing = false;

  /// "Watch more videos" nudge, shown once the viewer has stayed on this video
  /// for _watchMoreAfter without tapping it.
  Timer? _watchMoreTimer;
  bool _showWatchMore = false;

  Future<void> _ensureInit() async {
    if (_controller != null || _initializing) return;
    _initializing = true;
    final c = VideoPlayerController.networkUrl(Uri.parse(mediaUrl(widget.video.videoUrl)));
    try {
      await c.initialize();
      await c.setLooping(true);
    } catch (_) {
      c.dispose();
      _initializing = false;
      return;
    }
    if (!mounted) { c.dispose(); return; }
    setState(() { _controller = c; _initializing = false; });
    _applyVolume();
    _applyPlayback();
  }

  /// Only the card actually on screen may be heard — so scrolling past an
  /// unmuted video hands the sound to the next one instead of stacking two.
  void _applyVolume() {
    _controller?.setVolume(widget.soundOn && _visible ? 1 : 0);
  }

  @override
  void didUpdateWidget(covariant _VideoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The feed-wide sound setting changed (this card's speaker, or another
    // card's, was tapped) — follow it.
    if (widget.soundOn != oldWidget.soundOn) _applyVolume();
  }

  void _onVisibility(VisibilityInfo info) {
    // Start fetching/decoding the moment ANY sliver of the card enters the
    // viewport, not at the 60% play threshold. By the time it's centred the
    // first frame is ready, so it starts instantly instead of showing a dead
    // panel while the network catches up.
    if (info.visibleFraction > 0.01) _ensureInit();

    final visible = info.visibleFraction > 0.6;
    if (visible == _visible) return;
    _visible = visible;
    if (visible) {
      _startWatchMoreTimer();
    } else {
      _cancelWatchMore();
    }
    _applyPlayback();
    _applyVolume();
  }

  /// The card plays only while it's on screen AND the nudge isn't up — once
  /// "Watch more videos" appears the preview stops, so the choice is to tap
  /// through rather than keep half-watching a muted loop in a scroll feed.
  void _applyPlayback() {
    final c = _controller;
    if (c == null) return;
    if (_visible && !_showWatchMore) {
      if (!c.value.isPlaying) c.play();
    } else {
      if (c.value.isPlaying) c.pause();
    }
  }

  void _startWatchMoreTimer() {
    _watchMoreTimer?.cancel();
    _watchMoreTimer = Timer(_watchMoreAfter, () {
      if (!mounted) return;
      setState(() => _showWatchMore = true);
      _applyPlayback(); // the nudge is up — hold the video here
    });
  }

  void _cancelWatchMore() {
    _watchMoreTimer?.cancel();
    _watchMoreTimer = null;
    if (_showWatchMore && mounted) setState(() => _showWatchMore = false);
  }

  @override
  void dispose() {
    _watchMoreTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    final c = _controller;
    return Padding(
      padding: _cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          VisibilityDetector(
            key: Key('pubvid-${video.id}'),
            onVisibilityChanged: _onVisibility,
            child: GestureDetector(
              // Opens THIS video full-screen. It used to send you to the top of
              // the Shorts feed, which threw away the video actually tapped.
              onTap: () => context.push('/v/${video.id}', extra: video),
              child: AspectRatio(
                // The video's OWN shape, clamped so the ends stay sensible:
                // never taller than 4:5, so Public still reads as a scroll feed
                // rather than Shorts (a 9:16 clip filled the whole screen and
                // the next post's header got squeezed off the bottom), and
                // never wider than a letterbox 1.91:1.
                aspectRatio: video.aspectRatio.clamp(4 / 5, 1.91),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // The poster stays UNDERNEATH the player for the card's
                    // whole life — not swapped out for it. Any gap (still
                    // buffering, a frame dropped on a seek/loop) then shows the
                    // picture rather than a black panel. Black behind it, not
                    // the page's white: video letterboxes against black.
                    DecoratedBox(
                      decoration: const BoxDecoration(color: Colors.black),
                      child: video.thumbUrl != null
                          ? CachedNetworkImage(imageUrl: mediaUrl(video.thumbUrl!), fit: BoxFit.cover)
                          : null,
                    ),
                    if (c != null && c.value.isInitialized)
                      FittedBox(
                        fit: BoxFit.cover,
                        // FittedBox does NOT clip by default, and BoxFit.cover
                        // makes the child bigger than the box on purpose — so
                        // a portrait clip in this card painted its top and
                        // bottom OUTSIDE the card, over the post above and the
                        // post below. That is what made Public look like the
                        // videos were bleeding into everything around them,
                        // and no amount of changing the aspect ratio could fix
                        // it: the box was always the right size, the paint
                        // just wasn't kept inside it.
                        clipBehavior: Clip.hardEdge,
                        child: SizedBox(
                          width: c.value.size.width,
                          height: c.value.size.height,
                          child: VideoPlayer(c),
                        ),
                      ),

                    _MediaHeader(
                      displayName: video.user.displayName,
                      avatarUrl: video.user.avatarUrl != null ? mediaUrl(video.user.avatarUrl!) : null,
                      subtitle: _timeAgo(video.createdAt),
                      onTapAuthor: () => context.push('/profile/${video.user.username}'),
                    ),

                    // "Watch more videos" — appears in the MIDDLE of the frame
                    // once the viewer has stayed with this video a while, and
                    // the video holds there (see _applyPlayback). Tapping
                    // anywhere on the card opens it full-screen, so the nudge
                    // itself stays non-interactive.
                    IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _showWatchMore ? 1 : 0,
                        duration: const Duration(milliseconds: 260),
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.66),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 22),
                                const SizedBox(width: 8),
                                Text('Watch more videos',
                                    style: AppTypography.sans(
                                        fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    // Sound on / off for the WHOLE feed — tap doesn't bubble to
                    // the open-player tap.
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onSoundToggle,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                          child: Icon(widget.soundOn ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                              color: Colors.white, size: 18),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (video.caption.isNotEmpty)
            _CardFooter(children: [
              Text(video.caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.sans(fontSize: 15, color: _ink)),
            ]),
        ],
      ),
    );
  }
}

class _PostSkeleton extends StatelessWidget {
  const _PostSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 22),
      child: Column(
        children: [
          // onSheet: the light skeleton pair. The dark one is invisible against
          // a white page — it IS the page colour.
          AspectRatio(aspectRatio: 4 / 5, child: Skeleton(borderRadius: 0, onSheet: true)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              Skeleton(width: 80, height: 12, onSheet: true),
            ]),
          ),
        ],
      ),
    );
  }
}
