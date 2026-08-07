import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:belople_app/app.dart';

void main() {
  testWidgets('App boots to the Phase 0 component gallery', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: BelopleApp()));
    await tester.pumpAndSettle();

    expect(find.text('Belople'), findsOneWidget);
  });
}
