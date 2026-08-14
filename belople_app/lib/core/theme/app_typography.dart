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
  // --- A typed ❤️ renders WHITE, and nothing here can fix it ---
  //
  // Written down because it looks like a styling bug and three obvious fixes
  // all fail, so the next person should not spend the morning I did.
  //
  // ❤ is U+2764, an old symbol whose DEFAULT presentation is text. Inter has
  // its own monochrome glyph for it, so Inter answers for the character and
  // paints it in the text colour. 😀 is fine because it is emoji-only and no
  // text font has it, which is what makes this look like it is about hearts.
  //
  // What was tried on the device, and what happened:
  //
  //   1. fontFamilyFallback: ['Noto Color Emoji'] — no change. A fallback is
  //      only consulted when the primary font LACKS the glyph, and Inter has it.
  //   2. fontFamily: 'Noto Color Emoji' with Inter behind it — no change. On
  //      this phone /system/etc/fonts.xml declares the emoji families with
  //      `lang="und-Zsye"` and NO name attribute, so there is no family by that
  //      name to select. It is reachable only through the fallback chain.
  //   3. A plain TextStyle() in one field — still white, but that test was
  //      WORTHLESS: app_theme.dart sets fontFamily on the whole ThemeData, so
  //      the field inherited Inter regardless. Repeated properly by stripping
  //      the global family from the theme itself — STILL white. So it really is
  //      not our font choice.
  //
  // The U+FE0F that should force emoji presentation is genuinely in the data
  // (bytes E29DA4 EFB88F, checked in D1) and Flutter does not honour it. Every
  // other app on the same phone shows the heart red, including the keyboard
  // drawing its own preview a centimetre below ours — so this is Flutter's text
  // stack, not the device.
  //
  // The only fix left is to BUNDLE a colour emoji font with the app and name
  // it, which costs roughly 10 MB of APK. That is the owner's call, not a
  // decision to slip into a typography file.

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
