// Smoke test for the RAW viewer shell.
//
// Only covers the pre-decode state: anything past "Open RAW" needs a real
// RAW file and the native libraw_wrapper.so, which is out of scope for a
// widget test.

import 'package:flutter_test/flutter_test.dart';

import 'package:raw_viewer/main.dart';

void main() {
  testWidgets('shows the empty state before a file is opened',
      (WidgetTester tester) async {
    await tester.pumpWidget(const RawViewerApp());

    expect(find.text('RAW Viewer'), findsOneWidget);
    expect(find.text('Open RAW'), findsOneWidget);
    expect(find.text('Open a RAW file to begin'), findsOneWidget);
  });
}
