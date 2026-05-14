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

## Supabase backend

DateNow runs fully in mock mode while `.env` is empty — every feature is
exercisable end-to-end against in-memory repositories. To wire the real
backend:

1. **Install the CLI** — see <https://supabase.com/docs/guides/cli>.
2. **Create a project** at <https://supabase.com> and grab the project ref
   from `Settings → General`.
3. **Link + push migrations:**

   ```bash
   supabase link --project-ref <your-project-ref>
   supabase db push
   ```

   This applies every file under `supabase/migrations/`:

   | File | What it does |
   | --- | --- |
   | `20260513120000_initial_schema.sql` | Creates all 10 tables (`profiles`, `user_preferences`, `user_photos`, `weekly_suggestions`, `matches`, `calls`, `blocked_users`, `reports`, `subscriptions`, `user_settings`) plus a CHECK constraint enforcing the **18+ age floor** on `profiles.birth_date`. |
   | `20260513120100_rls_policies.sql` | Enables Row Level Security on every table and ships owner-scoped policies (matched users can read each other's profile + photos, suggested users can read each other's profile, the rest is private). |
   | `20260513120200_handle_new_user.sql` | Auto-creates a profile + preferences + settings + subscription row after each `auth.users` insert. Re-validates `first_name` + `birth_date` and refuses the signup transaction if the user is under 18. |
   | `20260513120300_storage.sql` | Creates the private `profile-photos` bucket and the matched-only `SELECT` policy on `storage.objects`. |

4. **Copy your project URL + anon key** from the dashboard into `.env`:

   ```
   SUPABASE_URL=https://<id>.supabase.co
   SUPABASE_ANON_KEY=<your-anon-key>
   ```

5. **Restart `flutter run`** — the app picks up the env, swaps every
   `Mock*Repository` for its Supabase-backed sibling, and the trigger
   bootstraps profile rows on each new signup.

### Age gate (18+)

The minor-block rule is enforced in **four** layers:

1. UI — `Validators.birthDate` in the sign-up form.
2. Controller — `AuthController.signUp` short-circuits before any network
   call when `isOfMinimumAge` fails.
3. Repository — both `SupabaseAuthRepository` and `MockAuthRepository`
   throw `MinorSignUpFailure` regardless of the caller. The mock cannot be
   bypassed either.
4. Database — `profiles.birth_date <= CURRENT_DATE - INTERVAL '18 years'`
   CHECK constraint **and** an explicit `RAISE EXCEPTION` inside
   `handle_new_user()` running in the same transaction as `auth.users`'s
   insert (so a failure rolls back the signup entirely).

## Design language

- **Palette** — deep near-black background (`#0A0A0F`), surface (`#14141C`),
  brand gradient `#FF3D7F → #B936FF`, glassmorphic overlays.
- **Typography** — Plus Jakarta Sans, tight letter-spacing on display sizes.
- **Motion** — `flutter_animate` for fade/slide entrances; pulsing dots and
  ripple rings on live states.
- **Components** — `AppButton`, `AppTextField`, `GlassCard`,
  `GradientBackground`, `StatusPill`, `AppLogo`.

All design tokens live in `lib/app/theme/`.
