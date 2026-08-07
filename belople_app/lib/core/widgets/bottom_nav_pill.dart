import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_motion.dart';
import '../theme/app_radii.dart';
import 'pressable.dart';

/// Ports design.css section 6 (BOTTOM NAV): a dark pill holding two tabs
/// with a lighter highlight sliding behind the active one, plus a separate
/// round FAB beside it whose job follows the active tab (Post on Feed, Add
/// friend on Messages).
class BottomNavPill extends StatelessWidget {
  const BottomNavPill({
    super.key,
    required this.items,
    required this.activeIndex,
    required this.onTap,
    required this.fabIcon,
    required this.onFabTap,
  });

  final List<({IconData icon, String label})> items;
  final int activeIndex;
  final ValueChanged<int> onTap;
  final IconData fabIcon;
  final VoidCallback onFabTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Container(
              height: 62,
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: AppColors.navBg,
                borderRadius: AppRadii.navPill,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 24,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final tabWidth = (constraints.maxWidth - 10) / items.length;
                  return Stack(
                    children: [
                      AnimatedPositioned(
                        duration: AppMotion.slide,
                        curve: AppMotion.slideCurve,
                        left: activeIndex * tabWidth,
                        top: 0,
                        bottom: 0,
                        width: tabWidth,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppColors.accentSoft,
                            borderRadius: BorderRadius.circular(26),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          for (var i = 0; i < items.length; i++)
                            Expanded(
                              child: _NavButton(
                                icon: items[i].icon,
                                label: items[i].label,
                                active: i == activeIndex,
                                onTap: () => onTap(i),
                              ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          Pressable(
            size: PressableSize.round,
            onTap: onFabTap,
            child: Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: AppColors.navBg,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 24,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Icon(fabIcon, color: AppColors.text),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.accent : AppColors.navInactive;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedScale(
            scale: active ? 1.1 : 1.0,
            duration: AppMotion.press,
            curve: AppMotion.pressCurve,
            child: Transform.translate(
              offset: Offset(0, active ? -1 : 0),
              child: Icon(icon, color: color, size: 22),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
