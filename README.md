# DateNow

> Live dates, in real time.

DateNow is a mobile-first dating app inspired by Tinder, Hinge and Raya — but
without manual swiping. The system auto-matches two compatible people who are
online right now, based on preferences, interests, availability and location,
then starts a 5-minute audio/video call instantly. After that, both users can
choose to keep talking, swap profiles, or move on.

## Stack

- Flutter (stable) — `^3.11.5`
- Riverpod (state)
- GoRouter (navigation)
- Supabase (auth + backend, init wired, ready to plug in)
- Freezed + json_serializable (immutable models)
- Plus Jakarta Sans via google_fonts (premium typography)
- flutter_animate (motion language)

## Project layout

```
lib/
├── main.dart                # Bootstrap: env + Supabase + ProviderScope
├── app/
│   ├── app.dart             # MaterialApp.router root
│   ├── router/              # GoRouter config + named routes
│   ├── scaffold/            # Bottom-nav shell
│   └── theme/               # Colors, typography, spacing, theme
├── core/
│   ├── config/              # Env + product constants
│   ├── constants/           # Storage keys, asset paths
│   ├── errors/              # Failure hierarchy
│   ├── services/            # Supabase + preferences
│   └── utils/               # Logger, validators, extensions
├── features/
│   ├── splash/
│   ├── onboarding/          # 3-step intro + completion flag
│   ├── auth/                # data + domain + providers + screens
│   ├── home/
│   ├── discover/
│   ├── matching/            # Auto-match placeholder w/ ripple animation
│   ├── call/                # 5-minute call placeholder w/ countdown
│   ├── profile/
│   └── settings/
└── shared/widgets/          # AppButton, AppTextField, GlassCard, …
```

## Getting started

```bash
cp .env.example .env
# fill in SUPABASE_URL and SUPABASE_ANON_KEY (or leave empty to run UI-only)

flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

When `.env` is empty, the app runs without Supabase — the auth flow simply
shows the landing screen and routes are unauthenticated.

### Regenerate freezed / json_serializable code

```bash
dart run build_runner watch --delete-conflicting-outputs
```

### Run tests

```bash
flutter test
```

## Design language

- **Palette** — deep near-black background (`#0A0A0F`), surface (`#14141C`),
  brand gradient `#FF3D7F → #B936FF`, glassmorphic overlays.
- **Typography** — Plus Jakarta Sans, tight letter-spacing on display sizes.
- **Motion** — `flutter_animate` for fade/slide entrances; pulsing dots and
  ripple rings on live states.
- **Components** — `AppButton`, `AppTextField`, `GlassCard`,
  `GradientBackground`, `StatusPill`, `AppLogo`.

All design tokens live in `lib/app/theme/`.
