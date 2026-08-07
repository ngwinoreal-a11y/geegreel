import 'package:flutter/material.dart';

/// Corner-radius tokens pulled from the recurring border-radius values across
/// design.css/design-2..5.css/design-public.css.
abstract final class AppRadii {
  static const sm = 6.0; // .grid .cell, .sk
  static const md = 10.0; // .field, .btn-primary, .pack, .sound-cover
  static const lg = 12.0; // .post-form .pick/.preview, comment images
  static const xl = 14.0; // .sheet top corners, .post-text-card
  static const pill = 20.0; // .interest-chip, chat/comment inputs
  static const round = 999.0; // fully round pills (.pub-vid-watchmore)

  static const sheetTop = BorderRadius.only(
    topLeft: Radius.circular(xl),
    topRight: Radius.circular(xl),
  );

  static const navPill = BorderRadius.all(Radius.circular(31)); // .navpill: 62px tall / 2
}
