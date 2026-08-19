// An icon-only AppButton must fit the box its caller gives it.
//
// Regression: the Discover card's dismiss control is an AppButton with an
// empty label inside a `SizedBox(width: 52)`. The button applied the label
// padding regardless — 24 pt a side — leaving 2 pt of content width for an
// 18 pt glyph and its 8 pt trailing gap. Every build of the Discover tab
// threw "A RenderFlex overflowed by 24 pixels on the right"; in release the
// stripes are invisible, so it shipped unnoticed.

import 'package:datenow/shared/widgets/app_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('icon-only button fits the 52 pt box the Discover card gives it',
      (tester) async {
    await tester.pumpWidget(_host(
      SizedBox(
        width: 52,
        child: AppButton(
          label: '',
          icon: Icons.close_rounded,
          variant: AppButtonVariant.secondary,
          expanded: false,
          onPressed: () {},
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
  });

  testWidgets('the glyph sits on the button centre, not beside a phantom gap',
      (tester) async {
    await tester.pumpWidget(_host(
      SizedBox(
        width: 52,
        child: AppButton(
          label: '',
          icon: Icons.close_rounded,
          variant: AppButtonVariant.secondary,
          expanded: false,
          onPressed: () {},
        ),
      ),
    ));

    final button = tester.getRect(find.byType(AppButton));
    final glyph = tester.getRect(find.byType(Icon));
    // The 8 pt gap that used to follow the icon pushed it 4 pt left of centre.
    expect(glyph.center.dx, moreOrLessEquals(button.center.dx, epsilon: 0.5));
  });

  testWidgets('a labelled button keeps its full padding and its gap',
      (tester) async {
    await tester.pumpWidget(_host(
      AppButton(
        label: 'Lancer un date',
        icon: Icons.bolt_rounded,
        onPressed: () {},
      ),
    ));

    expect(tester.takeException(), isNull);
    final glyph = tester.getRect(find.byType(Icon));
    final label = tester.getRect(find.byType(Text));
    expect(label.left - glyph.right, moreOrLessEquals(8, epsilon: 0.5));
  });
}
