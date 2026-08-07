import 'package:belople_app/core/widgets/skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Skeleton.cell sizes to width * 14/9, not the full viewport',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 90, child: Skeleton.cell()),
          ),
        ),
      ),
    );
    await tester.pump();

    final size = tester.getSize(find.byType(Skeleton));
    expect(size.width, 90);
    expect(size.height, closeTo(90 * 14 / 9, 0.5));
  });
}
