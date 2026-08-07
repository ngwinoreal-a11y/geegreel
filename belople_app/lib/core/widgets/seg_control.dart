import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_radii.dart';
import '../theme/app_typography.dart';

/// Ports design.css .seg — a row of equal-width segment buttons (e.g.
/// Following/Followers/Friends tab-style pickers used in settings-adjacent
/// pages). Not the same as the feed's .tabs (For You/Following/Public),
/// which floats over video with an underline — see [FeedTabs].
class SegControl extends StatelessWidget {
  const SegControl({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i < labels.length - 1 ? 6 : 0),
              child: GestureDetector(
                onTap: () => onChanged(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  decoration: BoxDecoration(
                    color: i == selectedIndex ? AppColors.text : AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadii.md),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    labels[i],
                    style: AppTypography.sans(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: i == selectedIndex ? AppColors.bg : AppColors.muted,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Ports design-feed.css's floating-over-video feed tabs (For You /
/// Following / Public): bold text, white underline on the active tab, text
/// shadow so it stays readable over any frame.
class FeedTabs extends StatelessWidget {
  const FeedTabs({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < labels.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: GestureDetector(
              onTap: () => onChanged(i),
              child: Container(
                padding: const EdgeInsets.only(bottom: 4),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      width: 2,
                      color: i == selectedIndex ? Colors.white : Colors.transparent,
                    ),
                  ),
                ),
                child: Text(
                  labels[i],
                  style: AppTypography.display(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: i == selectedIndex
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.55),
                  ).copyWith(
                    shadows: const [Shadow(color: Colors.black54, blurRadius: 6)],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Ports design.css .interest-chip — used in the signup wizard's interests
/// picker (max 5), a wrapping grid of toggle chips.
class InterestChip extends StatelessWidget {
  const InterestChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.text : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(
            color: selected ? AppColors.text : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: AppTypography.sans(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: selected ? AppColors.onAccent : AppColors.text,
          ),
        ),
      ),
    );
  }
}
