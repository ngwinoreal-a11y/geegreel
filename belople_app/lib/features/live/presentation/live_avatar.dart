import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../application/active_lives_controller.dart';

/// Someone's face with "on air" on it.
///
/// One widget, used everywhere a live creator's photo appears — the card in the
/// feed and the author of any of their videos — because the owner's complaint
/// was precisely that the two did not match. A ring drawn slightly differently
/// in two places reads as a mistake, not a style.
///
/// The ring is a real ring: the border sits on a container padded away from the
/// photo, so there is a gap between the two rather than a red outline stuck to
/// the edge of someone's head. The badge overlaps the bottom of it — which
/// means the widget draws [overhang] pixels BELOW its own box, and whatever
/// sits underneath needs that much clearance.
class LiveAvatar extends StatelessWidget {
  const LiveAvatar({
    super.key,
    required this.size,
    required this.displayName,
    this.imageUrl,
    this.live = true,
  });

  /// The photo's diameter. The ring and the badge scale off it, so a 42 and a
  /// 44 look like the same thing at different sizes rather than two designs.
  final double size;
  final String? displayName;
  final String? imageUrl;

  /// False draws the plain avatar with a white edge — the ordinary state, kept
  /// here so a caller can switch on one flag instead of building two trees.
  final bool live;

  /// How far the badge hangs below the box. Callers leave this much room.
  static double overhangFor(double size) => size * 0.14;

  @override
  Widget build(BuildContext context) {
    if (!live) {
      return AppAvatar(
        size: size,
        imageUrl: imageUrl,
        displayName: displayName,
        borderColor: Colors.white,
        borderWidth: 2,
      );
    }

    final ringGap = (size * 0.055).clamp(2.0, 4.0);
    final ringWidth = (size * 0.055).clamp(2.0, 3.0);
    final badgeFont = (size * 0.20).clamp(8.0, 11.0);

    return Stack(
      alignment: Alignment.bottomCenter,
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: EdgeInsets.all(ringGap),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.danger, width: ringWidth),
          ),
          child: AppAvatar(size: size, imageUrl: imageUrl, displayName: displayName),
        ),
        Positioned(
          bottom: -overhangFor(size),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: badgeFont * 0.7, vertical: 1),
            decoration: BoxDecoration(
              color: AppColors.danger,
              borderRadius: BorderRadius.circular(badgeFont * 0.45),
              // A dark edge so the badge stays legible sitting on the ring, on
              // a bright photo, or on both at once.
              border: Border.all(color: Colors.black, width: 1.2),
            ),
            child: Text('LIVE',
                style: AppTypography.sans(
                    fontSize: badgeFont,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    height: 1.25)),
          ),
        ),
      ],
    );
  }
}

/// A person's photo that knows whether they are on air.
///
/// Drops into any list of authors — the video feed, Public, anywhere a face
/// appears next to a name. If that person is broadcasting it wears the ring and
/// goes to the live; otherwise it is an ordinary avatar and does whatever the
/// screen normally does with a tap.
///
/// Owning the lookup here is the point: every caller would otherwise repeat the
/// same watch-and-search, and the ones that forgot would silently be the only
/// places in the app where a live creator looked offline.
class LiveAwareAvatar extends ConsumerWidget {
  const LiveAwareAvatar({
    super.key,
    required this.userId,
    required this.size,
    required this.displayName,
    this.imageUrl,
    this.onTap,
    this.ringWhenOffline = true,
  });

  final String userId;
  final double size;
  final String? displayName;
  final String? imageUrl;

  /// What a tap does when this person is NOT live — usually opening their
  /// profile. Ignored when they are: the live is the more interesting thing and
  /// the profile is one tap further in.
  final VoidCallback? onTap;

  /// Public draws its avatars with the app's own ring; the video feed uses a
  /// plain white edge. Only affects the offline state.
  final bool ringWhenOffline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref
        .watch(activeLivesProvider)
        .valueOrNull
        ?.where((s) => s.creator.id == userId)
        .firstOrNull;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: live != null ? () => context.push('/live/${live.id}') : onTap,
      child: Padding(
        // Room for the badge that hangs below the ring, so it lands on nothing.
        padding: EdgeInsets.only(bottom: live != null ? LiveAvatar.overhangFor(size) + 2 : 0),
        child: live != null
            ? LiveAvatar(size: size, imageUrl: imageUrl, displayName: displayName)
            : AppAvatar(
                size: size,
                ring: ringWhenOffline,
                imageUrl: imageUrl,
                displayName: displayName,
              ),
      ),
    );
  }
}
