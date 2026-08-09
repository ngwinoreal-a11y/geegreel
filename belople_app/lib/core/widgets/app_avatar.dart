import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

/// Ports the avatar pattern used everywhere in the CSS (.avatar, .av, .aav,
/// .me-btn, .notif-av, .cav, .voice-av, .post-av, ...): a circle, --raised
/// background, initials in the display font when there's no photo, image
/// cropped with object-fit:cover when there is one.
class AppAvatar extends StatelessWidget {
  const AppAvatar({
    super.key,
    required this.size,
    this.imageUrl,
    this.displayName,
    this.borderColor,
    this.borderWidth = 0,
    this.backgroundColor = AppColors.raised,
    this.textColor = AppColors.text,
    this.ring = false,
  });

  final double size;
  final String? imageUrl;
  final String? displayName;
  final Color? borderColor;
  final double borderWidth;
  final Color backgroundColor;
  final Color textColor;

  /// Wraps the avatar in an Instagram-style gradient story ring.
  final bool ring;

  static const _ringGradient = LinearGradient(
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
    colors: [Color(0xFFF9CE34), Color(0xFFEE2A7B), Color(0xFF6228D7)],
  );

  String get _initial {
    final n = displayName?.trim();
    if (n == null || n.isEmpty) return '?';
    return n[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: backgroundColor,
        border: borderWidth > 0
            ? Border.all(color: borderColor ?? AppColors.bg, width: borderWidth)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: (imageUrl != null && imageUrl!.isNotEmpty)
          ? CachedNetworkImage(
              imageUrl: imageUrl!,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => _initials(),
              placeholder: (_, _) => _initials(),
            )
          : _initials(),
    );
    if (!ring) return avatar;
    // Gradient story ring with a thin dark gap between it and the photo.
    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: const BoxDecoration(shape: BoxShape.circle, gradient: _ringGradient),
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.bg),
        child: avatar,
      ),
    );
  }

  Widget _initials() {
    return Center(
      child: Text(
        _initial,
        style: AppTypography.display(
          fontSize: size * 0.32,
          fontWeight: FontWeight.w700,
          color: textColor,
        ),
      ),
    );
  }
}
