import 'package:flutter/material.dart';
import '../theme/app_typography.dart';

/// The Belople wordmark painted in the brand gradient — the app's "logo" in a
/// screen header, the way Instagram sets its name. Same gradient as the avatar
/// story rings so the brand reads as one system.
class BrandWordmark extends StatelessWidget {
  const BrandWordmark({super.key, this.fontSize = 25});
  final double fontSize;

  static const brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF9CE34), Color(0xFFEE2A7B), Color(0xFF6228D7)],
  );

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => brandGradient.createShader(bounds),
      child: Text('Belople',
          style: AppTypography.display(fontSize: fontSize, fontWeight: FontWeight.w800, color: Colors.white)),
    );
  }
}
