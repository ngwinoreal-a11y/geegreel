import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Page snapping tuned for a full-screen vertical feed: a flick lands on the
/// next page fast and stops dead.
///
/// Lifted out of the feed so the live pager gets the same feel instead of a
/// second set of numbers that would drift from it. Swiping between lives and
/// swiping between videos are the same gesture and must not feel different.
class SnappyPageScrollPhysics extends PageScrollPhysics {
  const SnappyPageScrollPhysics({super.parent});

  @override
  SnappyPageScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      SnappyPageScrollPhysics(parent: buildParent(ancestor));

  // withDampingRatio, NOT a raw damping coefficient: ratio 1.0 is critically
  // damped — the fastest snap that DOESN'T overshoot. (A raw damping of 1.0 is
  // far below critical for this mass/stiffness, so the page sprang up then
  // bounced and vibrated before settling.) High stiffness keeps the flick
  // fast; ratio 1.0 makes it land once and stop.
  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
        // Stiff and light, so the page snaps up fast and the spring's settle
        // tail is over almost instantly — that long, slow final approach was
        // the "catch" felt at the end of every swipe.
        mass: 0.3,
        stiffness: 560,
        ratio: 1.0,
      );
}
