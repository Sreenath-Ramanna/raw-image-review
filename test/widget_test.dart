// Smoke test for the RAW viewer shell.
//
// Only covers the pre-decode state: anything past "Open RAW" needs a real
// RAW file and the native libraw_images_api.so, which is out of scope for a
// widget test.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raw_viewer/main.dart';

void main() {
  testWidgets('shows the empty state before a file is opened',
      (WidgetTester tester) async {
    await tester.pumpWidget(const RawViewerApp());

    expect(find.text('RAW Viewer'), findsOneWidget);
    expect(find.text('Open Folder'), findsOneWidget);
    expect(find.text('Open a folder of RAW images to begin'), findsOneWidget);

    // Navigation only appears once a folder has been opened.
    expect(find.byIcon(Icons.chevron_left), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });
}
