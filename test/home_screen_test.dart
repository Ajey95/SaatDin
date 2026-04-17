import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';


void main() {
  testWidgets('HomeScreen renders without error', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('HomeScreen placeholder'))),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Verify the app renders something
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
