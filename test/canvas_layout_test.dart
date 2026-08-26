// Regression test for the blank-canvas bug.
//
// A CustomPaint with no child sizes itself from its `size` property, which
// defaults to Size.zero. Row's default crossAxisAlignment is .center, which
// passes *loose* vertical constraints to its children, so constrain(Size.zero)
// collapses the painter to zero height: full width, nothing drawn.
//
// The decoded image was fine; it was being painted into a zero-height box.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _ProbePainter extends CustomPainter {
  const _ProbePainter();
  @override
  void paint(Canvas canvas, Size size) {}
  @override
  bool shouldRepaint(_ProbePainter oldDelegate) => false;
}

void main() {
  testWidgets('image canvas fills the height it is given',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Container(height: 48), // toolbar
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: ClipRect(
                        // Must fill the available box; without an explicit
                        // expand this collapses to zero height.
                        child: SizedBox.expand(
                          child: CustomPaint(
                            painter: const _ProbePainter(),
                          ),
                        ),
                      ),
                    ),
                    Container(width: 220), // EXIF panel
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final size = tester.getSize(find.byType(CustomPaint).last);
    expect(size.height, greaterThan(0),
        reason: 'canvas collapsed to zero height — image cannot render');
    expect(size.width, greaterThan(0));
  });
}
