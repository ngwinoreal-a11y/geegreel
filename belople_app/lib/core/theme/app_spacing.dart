/// Spacing scale. The CSS source doesn't define a formal spacing scale (it
/// hand-picks px values per rule), so these are the recurring values pulled
/// out across design.css/design-2..5.css/design-public.css — use the closest
/// one rather than inventing a new magic number.
abstract final class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;

  /// .page padding: 16px 20px 100px — horizontal page gutter
  static const pageHorizontal = 20.0;

  /// .page padding-bottom — clears the bottom nav pill
  static const pageBottomClearance = 100.0;

  /// --feed-top (design.css fallback; design-feed.css overrides the actual
  /// feed layout to be full-bleed with no top band — see AppMotion doc note)
  static const feedTop = 100.0;

  /// design-feed.css's bottom black strip height (nav pill + scrub bar, see
  /// that file's own math: nav pill top edge at 78px + scrub 84-106px zone)
  static const feedBottomStrip = 112.0;

  /// --pub-pad (design-public.css): horizontal padding inside a Public post
  static const publicPostPadding = 14.0;
}
