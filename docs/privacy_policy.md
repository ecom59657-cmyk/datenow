# DateNow — Privacy Policy

**Effective date:** 24 May 2026
**Last updated:** 24 May 2026
**Contact:** privacy@datenow.app

> ⚠️ This document is the **product-grade MVP template**, written to be
> credible enough for Apple App Store / TestFlight review and to mirror
> the in-app `PrivacyPolicyScreen`. It is **not legal advice** — before
> a public launch, have it reviewed by counsel for your jurisdiction
> (GDPR / CCPA / national consumer-law specifics).

---

## 1. Who we are

DateNow is a live-matching dating application that connects two
compatible, online members for a 5-minute video date, then offers a
mutual reveal. The service is operated by the DateNow team. Questions:
**privacy@datenow.app**. General support: **support@datenow.app**.

## 2. What we collect

| Category | Examples | Source |
|----------|----------|--------|
| Account | email, password (hashed), creation date | you, at sign-up |
| Profile | first name, birth date, gender, sexual orientation, preferences, intentions, interests, distance preference | you, at onboarding + profile edits |
| Background (optional) | drinking, smoking, education | you, at onboarding — used to refine suggestions |
| Background, sensitive (optional) | ethnic origins, religion | you, at onboarding — **special category data under article 9 GDPR**; weighed in suggestions only with your explicit, separate consent, and only when both people have given it |
| Location | approximate coordinates and the time they were taken | your device, when you allow it — required to find people near you |
| Photos | up to 6 profile photos | you, from your device |
| Matching state | active queue presence, compatibility scores | computed |
| Calls | caller / callee ids, channel name, start / end timestamps, ready flags | server, during a date |
| Reveals | per-call reveal decision (true / false) | you, at the post-date screen |
| Matches | mutual matches, conversation references | server, after a mutual reveal |
| Messages | text body, timestamps, read state | you, in chat |
| Reports | reason, optional details | you, when you file a report |
| Blocks | blocked user ids | you, when you block |
| Settings | notification toggles, privacy toggles | you, from Settings |
| Technical | device model, OS version, error logs (anonymised) | automatic |

**Location.** DateNow matches on proximity, so it needs a position. Your
coordinates are captured only when the app is in the foreground and you have
allowed it, never in the background, and they are stored as a single point
that is overwritten on each refresh — we keep no history of where you have
been. Other people never see your position; they see a distance.

**Advertising identifier.** If you agree to the tracking prompt, Google
AdMob may use your device's advertising identifier to select the rewarded
video shown when you ask for an extra date. Declining changes nothing except
how relevant those videos are.

We **do not collect**: contacts, browsing history, microphone or camera
input outside of an active date, background location.

## 3. How we use your data

- Propose **compatible matches**, ranked by a compatibility score built from
  your intentions, interests, distance, age and — where you provided them and,
  for the sensitive ones, explicitly agreed — your background answers.
- Operate the **5-minute video date** (Agora.io as our video provider).
- Secure your account (Supabase Auth handles passwords + session tokens).
- Process **reports** and apply moderation actions.
- Send **notifications** that you have opted in to.
- Improve the **matching quality** with anonymised aggregates.

We **never** sell your data.

Advertising is limited to one place: the rewarded video you can choose to
watch to earn an extra date for the day. It is opt-in — nothing is shown
unless you ask for it — and there are no banners or interstitials anywhere in
the app. Google AdMob serves that video and receives what it needs to do so;
if you decline the tracking prompt it still works, with less relevant videos.
We do not build advertising profiles, and your profile answers are never sent
to an advertiser.

## 4. Camera and microphone (Agora video)

During a live date your camera and microphone are activated through the
Agora.io SDK. Key facts:

- The audio + video stream is **not recorded** on our servers.
- The camera is **always blurred** during the date — the blur only lifts
  at the post-date reveal, and only if **both** people opted in.
- The video channel is bound to a short-lived (15 min) **server-signed
  token** scoped to your user id and to that exact channel name. The
  Agora App Certificate (the secret used to sign tokens) **never** leaves
  our server.

## 5. Photos

- Photos are stored privately in our Supabase Storage bucket.
- They are visible to another user **only after a mutual match** (both
  people opted in at the post-date reveal).
- Before that point, the other side sees a generic silhouette.
- You can delete a photo at any time from **Edit my photos**.

## 6. Sharing with third parties

We share strictly with the providers we need to run the service:

| Provider | Role | Region |
|----------|------|--------|
| Supabase | database, authentication, storage, edge functions | EU |
| Agora.io | real-time video / audio infrastructure | global |
| Apple App Store / TestFlight | distribution + crash reporting | global |
| Google AdMob | serves the opt-in rewarded video only | global |

We do **not** share with data-broker networks, and no provider above receives
your profile answers, your messages, or your location.

## 7. Reporting and moderation

- Every user can **report** a profile from the post-date screen or from
  a conversation (`Signaler` / `Report` menu).
- Reports are confidential. We never disclose the reporter's identity.
- A user who is reported may be **suspended without notice** if our
  review finds policy violations.

## 8. Protection of minors

- DateNow is strictly **reserved to people 18 and older**.
- Age enforcement runs at four layers: client-side validator, sign-up
  repository, server-side trigger, and a PostgreSQL `CHECK` constraint on
  the `profiles` table.
- Any profile flagged as belonging to a minor is suspended immediately
  via the **"Profile appears to be a minor"** report category.
- We are preparing integration with a third-party identity verification
  provider for production.

## 9. Account deletion

From **Settings → Delete my account** you can permanently remove your
account at any time. Deletion runs server-side and wipes:

- your profile and preferences,
- your photos,
- your matchmaking queue + presence,
- your matches, conversations, messages,
- your reveal decisions,
- your authentication entry.

The deletion is irreversible. The same email can later be used to
register a new account.

## 10. Your rights

Subject to your local law (GDPR / CCPA / equivalent), you can:

- **access** your data (Edit my profile),
- **correct** it (Edit my profile),
- **delete** it (Settings → Delete my account),
- **object** to certain processing,
- **lodge a complaint** with your supervisory authority.

We honour requests within 30 days.

## 11. Retention

We keep your data as long as your account is active. After deletion
(§9) it is wiped immediately. Security logs (sign-in attempts, abuse
signals) are kept for a maximum of **30 days** then purged.

## 12. Security

- Passwords are hashed by Supabase Auth.
- Network traffic is HTTPS-only.
- Row-Level Security is enabled on every table — a user only ever
  reads or writes their own rows (or those of a peer once a mutual
  match exists).
- Agora tokens are server-signed and short-lived.

## 13. Changes to this policy

We may update this policy. If we make a material change, we will notify
you in-app **before** the new version takes effect.

## 14. Contact

| Topic | Address |
|-------|---------|
| Privacy questions | privacy@datenow.app |
| Report abuse / safety | support@datenow.app |
| General support | support@datenow.app |
