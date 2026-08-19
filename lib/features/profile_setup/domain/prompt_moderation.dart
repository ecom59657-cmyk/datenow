/// Why a prompt answer was refused.
enum PromptRejection {
  /// Contact details — email, phone, a link, a social handle.
  contact,

  /// A term from the server-side list.
  term,
}

/// Client-side half of the Guideline 1.2 filter.
///
/// The authority is the database trigger (`enforce_prompt_moderation`): the
/// check has to hold against a tampered client, and a rule that only lives
/// in the app is not a rule. What runs here is the cheap, structural half —
/// the shapes of contact details — so the user is told *while typing*
/// instead of after a failed save.
///
/// The term list deliberately does NOT live here. Shipping it in the binary
/// publishes the very thing it filters, and anyone can read a Flutter bundle.
class PromptModeration {
  const PromptModeration._();

  static final _patterns = <RegExp>[
    // Email.
    RegExp(r'[\w.%+-]+@[\w.-]+\.[a-zA-Z]{2,}'),
    // Phone: eight or more digits, however they are spaced out.
    RegExp(r'(\+?\d[\s.-]?){8,}'),
    // Links.
    RegExp(r'(https?://|www\.)\S+', caseSensitive: false),
    // Named platforms — the usual "let's talk over there" move.
    RegExp(
      r'\b(instagram|insta|snapchat|snap|telegram|whatsapp|tiktok|onlyfans)\b',
      caseSensitive: false,
    ),
    // @handle.
    RegExp(r'@[\w.]{3,}'),
  ];

  /// `null` when nothing structural was found. A clean result here does NOT
  /// mean the server will accept it — that is the point of the trigger.
  static PromptRejection? check(String text) {
    final value = text.trim();
    if (value.isEmpty) return null;
    for (final pattern in _patterns) {
      if (pattern.hasMatch(value)) return PromptRejection.contact;
    }
    return null;
  }

  /// Maps the trigger's `prompt_rejected:<kind>` message back to a reason.
  /// Anything unrecognised falls back to [PromptRejection.term], which is
  /// the vaguer of the two messages — better than surfacing a Postgres
  /// error to someone who wrote a sentence about their Sunday.
  static PromptRejection? fromServerError(Object error) {
    final text = error.toString();
    if (!text.contains('prompt_rejected')) return null;
    return text.contains('prompt_rejected:contact')
        ? PromptRejection.contact
        : PromptRejection.term;
  }
}
