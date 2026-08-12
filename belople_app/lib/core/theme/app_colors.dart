import 'package:flutter/material.dart';

/// Colour tokens ported 1:1 from the web app's design source of truth:
/// public/design.css (:root), public/design-2.css, design-3.css, design-4.css,
/// design-5.css, design-public.css. Keep names aligned to the CSS custom
/// property they came from so a change on either side is easy to cross-check.
///
/// Do not hand-pick colours elsewhere in the app — every screen should read
/// from here, exactly like the web app reads from its `:root` tokens.
abstract final class AppColors {
  // --- Surfaces (design.css) ---
  /// --bg: app background.
  ///
  /// Lifted off pure black. #000 on an OLED phone reads as a hole rather than
  /// a surface — text sits on nothing, cards have no edge to sit against, and
  /// the whole app looks harsher than it is. A few points of lift keeps the
  /// dark feel while giving every layer above it something to sit on. Video
  /// still plays on true black; this is chrome only.
  static const bg = Color(0xFF0C0C0F);

  /// --surface: cards, inputs, seg buttons
  static const surface = Color(0xFF17171B);

  /// --raised: avatars, grid cells
  static const raised = Color(0xFF212127);

  /// --border: hairlines
  static const border = Color(0xFF34343A);

  // --- Text (design.css) ---
  static const text = Color(0xFFFFFFFF);

  /// --muted: secondary text, labels
  static const muted = Color(0xFF8E8E93);

  /// --faint: tertiary. NOTE: measured at only 3.15:1 on black per
  /// design-4.css's own audit — do not use for small body text, only for
  /// large/decorative text where the contrast shortfall doesn't bite.
  static const faint = Color(0xFF5C5C5E);

  // --- Floating chrome: white pills that sit over video (design.css) ---
  static const chrome = Color(0xFFFFFFFF);
  static const chip = Color(0xFFF0EBE0);
  static const onChrome = Color(0xFF111111);
  static const onChromeMuted = Color(0xFF8A8A8E);

  /// --on-sheet-muted: secondary text on a WHITE sheet (comment names,
  /// timestamps, "Reply"). Deliberately darker than onChromeMuted — that one
  /// only reaches 3.4:1 on white; this reaches 5.1:1.
  static const onSheetMuted = Color(0xFF6E6E73);

  // --- Accent (design.css) ---
  /// --accent: the amber used for the active nav tab. Light colour — anything
  /// placed ON it must use onAccent, never white/light text.
  static const accent = Color(0xFFF5A623);

  /// --accent-soft: the sliding highlight behind the active nav tab
  static const accentSoft = Color(0xFF3A3A3C);

  /// --on-accent: text/icons placed on top of `accent`
  static const onAccent = Color(0xFF111111);

  // --- Dark nav chrome (design.css) ---
  static const navBg = Color(0xFF1C1C1E);
  static const navInactive = Color(0xFF9A9A9E);

  // --- design-2.css ---
  /// --badge: unread counts — legible with white numerals (was #FE2C55 at
  /// 3.68:1, corrected to 4.97:1)
  static const badge = Color(0xFFD91F42);

  /// --online: presence dot / online-tag text
  static const online = Color(0xFF3AD35A);

  /// --tick-sent: one grey tick (delivered, not read)
  static const tickSent = Color(0xFF7A7A7E);

  /// --tick-read: two blue ticks (read)
  static const tickRead = Color(0xFF2F7FD4);

  /// --unread-tint: row background for anything unread
  static const unreadTint = Color(0xFF141416);

  /// --sponsor: the "Sponsored" label on ad slides
  static const sponsor = Color(0xFFC9A227);

  // --- design-3.css: bottom sheets are white, not dark, unlike the rest of
  // the app (comments sheet, more-options sheet, share/repost sheet) ---
  static const sheetBg = Color(0xFFFFFFFF);
  static const sheetLine = Color(0xFFEDEDED);
  static const sheetInk = Color(0xFF111111);
  static const sheetMuted = Color(0xFF6E6E73);
  static const sheetFill = Color(0xFFF1F1F2);
  static const repostGold = Color(0xFFF5C518);

  /// --send: the send arrow in the comment composer
  static const send = Color(0xFFFE2C55);

  /// Report is the one destructive action in the more-options sheet.
  static const danger = Color(0xFFC4162E);

  // --- design-4.css: skeleton loading ---
  static const skBase = Color(0xFF1C1C1C);
  static const skLift = Color(0xFF2A2A2E);
  static const skSheet = Color(0xFFEAEAEC);
  static const skSheetLift = Color(0xFFF4F4F6);

  // --- design-5.css: video scrubber ---
  static const scrubTrack = Color(0x48FFFFFF); // rgba(255,255,255,.28)
  static const scrubFill = Color(0xFFFFFFFF);

  // --- design-public.css: Public (photo feed) tab ---
  /// --verified: the verified tick (role === 'admin' ONLY — never decorative)
  static const verified = Color(0xFF3897F0);

  // --- Toast / error (design.css / design-5.css) ---
  static const error = Color(0xFFFF6B6B);
  static const toastBadBg = Color(0xFF2A1416);
  static const toastBadText = Color(0xFFFFD9DD);

  /// The Public tab's photo-post comment sheet is dark (#1A1A1A), unlike the
  /// video feed's white comment sheet — see design-public.css section E for
  /// why (it opens far more often, so a white flash every time is fatiguing).
  static const publicSheetBg = Color(0xFF1A1A1A);
}
