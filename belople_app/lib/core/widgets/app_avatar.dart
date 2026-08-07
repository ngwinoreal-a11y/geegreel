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
  });

  final double size;
  final String? imageUrl;
  final String? displayName;
  final Color? borderColor;
  final double borderWidth;
  final Color backgroundColor;
  final Color textColor;

  String get _initial {
    final n = displayName?.trim();
    if (n == null || n.isEmpty) return '?';
    return n[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
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
          ? Image.network(
              imageUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _initials(),
            )
          : _initials(),
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
