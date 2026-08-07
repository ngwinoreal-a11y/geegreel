import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

/// Type tokens ported from design.css's `--sans` / `--display` / `--mono`
/// triad:
///   sans (Inter)              — everything except headings/usernames/numbers
///   display (Space Grotesk)   — headings and usernames
///   mono (IBM Plex Mono)      — numbers: counts, durations, money, so digits
///                                line up (see .statn, .rail .n, wallet, etc.)
///
/// Use these text styles instead of ad-hoc `TextStyle(...)` calls so every
/// screen automatically matches the reference's type system.
abstract final class AppTypography {
  static TextStyle sans({
    double fontSize = 14,
    FontWeight fontWeight = FontWeight.w400,
    Color color = AppColors.text,
    double? height,
  }) =>
      GoogleFonts.inter(
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        height: height,
      );

  static TextStyle display({
    double fontSize = 22,
    FontWeight fontWeight = FontWeight.w800,
    Color color = AppColors.text,
  }) =>
      GoogleFonts.spaceGrotesk(
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
      );

  static TextStyle mono({
    double fontSize = 12,
    FontWeight fontWeight = FontWeight.w500,
    Color color = AppColors.text,
  }) =>
      GoogleFonts.ibmPlexMono(
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
      );

  // --- Named styles matching specific CSS rules, for direct reuse ---

  /// .page h2 — page heading
  static TextStyle get pageHeading =>
      display(fontSize: 22, fontWeight: FontWeight.w800);

  /// .author .aname — author name on a feed slide
  static TextStyle get authorName =>
      sans(fontSize: 15, fontWeight: FontWeight.w600);

  /// .caption — video caption text
  static TextStyle get caption => sans(fontSize: 14, height: 1.35);

  /// .statn — profile stat numbers (Following/Followers/Likes)
  static TextStyle get statNumber =>
      mono(fontSize: 22, fontWeight: FontWeight.w600);

  /// .statl — profile stat label under the number
  static TextStyle get statLabel => sans(fontSize: 13, color: AppColors.muted);

  /// .rail .n — action-rail counts (like/comment/share counts on a video)
  static TextStyle get railCount => mono(fontSize: 12, fontWeight: FontWeight.w500);

  /// .sect — settings section header. CSS also sets text-transform:uppercase
  /// letter-spacing:.5px — apply `.toUpperCase()` to the string yourself
  /// (Flutter has no text-transform), the letterSpacing below covers the rest.
  static TextStyle get sectionLabel => sans(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: AppColors.muted,
      ).copyWith(letterSpacing: 0.5);
}
