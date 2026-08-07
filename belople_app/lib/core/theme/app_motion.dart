import 'package:flutter/material.dart';

/// Motion tokens ported from design.css's `--press` / `--settle` / `--slide`.
/// Every duration in the reference sits between .18s and .32s: fast enough to
/// feel responsive, slow enough to read as movement. Match these rather than
/// picking new durations/curves per screen.
abstract final class AppMotion {
  /// --press: springy, slight overshoot. Used for every button press
  /// (`button:active { transform: scale(.9) }` in design.css).
  static const press = Duration(milliseconds: 180);
  static const pressCurve = Cubic(0.34, 1.56, 0.64, 1);

  /// --settle: decelerating, for arrivals (page transitions, feed slide
  /// landing "thud").
  static const settle = Duration(milliseconds: 280);
  static const settleCurve = Cubic(0.22, 0.61, 0.36, 1);

  /// --slide: the bottom-nav active-tab highlight sliding between tabs.
  static const slide = Duration(milliseconds: 300);
  static const slideCurve = Cubic(0.4, 0, 0.2, 1);

  /// Bottom-sheet open animation (design.css `.sheet { animation: up .32s
  /// cubic-bezier(.22,.61,.36,1) }`).
  static const sheetOpen = Duration(milliseconds: 320);
  static const sheetOpenCurve = Cubic(0.22, 0.61, 0.36, 1);

  // --- Press-feedback scale factors (design.css .tap / .tap-cell / .tap-sm) ---
  /// Large tap targets (full-width rows) press less so they don't lurch.
  static const tapScaleLarge = 0.97;
  static const tapScaleCell = 0.94;
  static const tapScaleSmall = 0.9;

  /// Round controls (fab, nav side buttons) squash less so they don't look
  /// dented.
  static const tapScaleRound = 0.92;
}
