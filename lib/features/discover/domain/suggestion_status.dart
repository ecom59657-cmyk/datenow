/// Lifecycle of a [WeeklySuggestion]:
/// - `pending`     — fresh suggestion the user hasn't acted on yet
/// - `dismissed`   — user removed the suggestion; never proposed again
/// - `callStarted` — user tapped "Start a date" but the post-call decision
///                   hasn't completed yet
/// - `matched`     — both sides confirmed after the call
enum SuggestionStatus { pending, dismissed, callStarted, matched }
