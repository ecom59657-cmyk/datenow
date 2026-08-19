import 'package:freezed_annotation/freezed_annotation.dart';

import 'prompt.dart';

part 'prompt_answer.freezed.dart';

/// One answered question on a profile.
///
/// [position] is persisted so the order the user chose survives a reload —
/// the first answer is the one surfaced on a Discover card and during the
/// call, so it is not an arbitrary sort.
@freezed
class PromptAnswer with _$PromptAnswer {
  const factory PromptAnswer({
    required PromptQuestion question,
    required String answer,
    @Default(0) int position,
  }) = _PromptAnswer;

  const PromptAnswer._();

  bool get isFilled => answer.trim().isNotEmpty;
}
