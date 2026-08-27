// The two sliders on the "who are you looking for" step, driven by a thumb.
//
// A slider is the one control where "it compiles" says almost nothing: the
// bounds, the step size and the write-back are three separate things, and a
// wrong `divisions` value produces a control that moves smoothly on screen
// and stores the wrong number. These tests drive the real widget and read
// the draft that comes out the other side.

import 'package:datenow/features/profile_setup/presentation/providers/profile_setup_controller.dart';
import 'package:datenow/features/profile_setup/presentation/steps/seeking_step.dart';
import 'package:datenow/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host() => const ProviderScope(
      child: MaterialApp(
        locale: Locale('fr'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SeekingStep()),
      ),
    );

Future<void> _pump(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_host());
  await tester.pumpAndSettle();
}

ProfileDraft _draft(WidgetTester tester) {
  final element = tester.element(find.byType(SeekingStep));
  return ProviderScope.containerOf(element)
      .read(profileSetupControllerProvider);
}

/// Drags the thumb currently sitting at [fromFraction] of the track to
/// [toFraction]. Fractions are 0 = left edge, 1 = right edge.
Future<void> _dragThumb(
  WidgetTester tester,
  Finder slider,
  double fromFraction,
  double toFraction,
) async {
  final box = tester.getRect(slider);
  // Inset so the grab point is on the track, never on the very edge pixel.
  const inset = 12.0;
  final usable = box.width - inset * 2;
  final start = Offset(box.left + inset + usable * fromFraction, box.center.dy);
  final end = Offset(box.left + inset + usable * toFraction, box.center.dy);
  await tester.dragFrom(start, end - start);
  await tester.pumpAndSettle();
}

void main() {
  group('age range slider', () {
    testWidgets('opens on the documented default, 18–40', (tester) async {
      await _pump(tester);
      final d = _draft(tester);
      expect(d.seekingAgeMin, 18);
      expect(d.seekingAgeMax, 40);
      // The label above the slider must agree with the state behind it.
      expect(find.text('18 – 40'), findsOneWidget);
    });

    testWidgets('the upper thumb moves and writes back', (tester) async {
      await _pump(tester);
      final slider = find.byType(RangeSlider);
      // 40 sits at (40-18)/62 ≈ 0.355 of the track. Drag it to the far end.
      await _dragThumb(tester, slider, 0.355, 1.0);

      final d = _draft(tester);
      expect(d.seekingAgeMax, greaterThan(40), reason: 'the thumb must move');
      expect(d.seekingAgeMin, 18, reason: 'the other thumb must stay put');
    });

    testWidgets('80 is a hard ceiling', (tester) async {
      await _pump(tester);
      // Push well past the right edge — the value must clamp, not overflow.
      await _dragThumb(tester, find.byType(RangeSlider), 0.355, 3.0);
      expect(_draft(tester).seekingAgeMax, 80);
    });

    testWidgets('18 is a hard floor — nobody can seek a minor',
        (tester) async {
      await _pump(tester);
      await _dragThumb(tester, find.byType(RangeSlider), 0.0, -3.0);
      expect(_draft(tester).seekingAgeMin, 18);
    });

    testWidgets('the thumbs cannot cross each other', (tester) async {
      await _pump(tester);
      // Shove the lower thumb far past the upper one.
      await _dragThumb(tester, find.byType(RangeSlider), 0.0, 1.0);
      final d = _draft(tester);
      expect(d.seekingAgeMin, lessThanOrEqualTo(d.seekingAgeMax));
    });

    testWidgets('the step is one whole year, never a fraction',
        (tester) async {
      // 62 divisions across 18..80 is exactly one year per notch. A wrong
      // divisions count shows up here as a value the label cannot render.
      await _pump(tester);
      await _dragThumb(tester, find.byType(RangeSlider), 0.355, 0.6);
      final d = _draft(tester);
      expect(d.seekingAgeMax, inInclusiveRange(18, 80));
      expect(find.text('${d.seekingAgeMin} – ${d.seekingAgeMax}'),
          findsOneWidget);
    });
  });

  group('distance slider', () {
    testWidgets('opens on 50 km and moves', (tester) async {
      await _pump(tester);
      expect(_draft(tester).maxDistanceKm, 50);

      final slider = find.byType(Slider);
      // 50 km sits at (50-5)/195 ≈ 0.23 of the track.
      await _dragThumb(tester, slider, 0.23, 1.0);
      expect(_draft(tester).maxDistanceKm, 200, reason: 'ceiling is 200 km');
    });

    testWidgets('5 km is the floor', (tester) async {
      await _pump(tester);
      await _dragThumb(tester, find.byType(Slider), 0.23, -2.0);
      expect(_draft(tester).maxDistanceKm, 5);
    });

    testWidgets('every stop is a multiple of 5 km', (tester) async {
      // 39 divisions across 5..200 gives exactly 5 km per notch.
      await _pump(tester);
      for (final target in [0.35, 0.5, 0.77]) {
        await _dragThumb(tester, find.byType(Slider), 0.23, target);
        final km = _draft(tester).maxDistanceKm;
        expect(km % 5, 0, reason: '$km km is not on a 5 km notch');
      }
    });
  });
}
