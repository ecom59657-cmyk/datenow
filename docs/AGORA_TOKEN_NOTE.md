# Agora token — future hardening

## État actuel (MVP)

L'app passe `tempToken: null` à `AgoraConnectionData`. Ça fonctionne tant
que le projet Agora est en **mode "App ID only" (Testing)** côté
[Agora Console → Project Management].

Aucun token n'est requis. C'est suffisant pour le MVP.

## Quand on bascule en prod

Dès que le projet Agora passe en mode **"App ID + Token"** (recommandé
en prod), il faudra signer un token côté serveur. L'anon key ne suffit
pas — l'`AGORA_APP_CERTIFICATE` est secret et ne doit JAMAIS quitter
Supabase.

### Réintroduction de l'Edge Function

Re-créer `supabase/functions/agora-token/index.ts` avec :

1. Auth obligatoire (Bearer JWT du caller).
2. Validation : le caller doit être `caller_id` ou `callee_id` d'une row
   `public.calls` avec `channel_name = <demande>` et `status <> 'ended'`.
3. Signature via `npm:agora-token@2.0.5`, `RtcRole.PUBLISHER`, TTL 10 min.
4. Retour `{ token, appId, channelName, uid, expiresAt }`.

Le code complet a déjà existé dans le repo — voir l'historique git autour
de mai 2026 (`supabase/functions/agora-token/`).

### Côté Flutter

Créer un repo `AgoraTokenRepository` qui invoque la fonction, et passer
le `token.token` au `AgoraConnectionData(tempToken: ...)` dans
`AgoraCallView`. Refresh avant expiration via le callback
`onTokenPrivilegeWillExpire` (déjà câblé pour log).

### Secrets à remettre

```bash
supabase secrets set AGORA_APP_CERTIFICATE=<value>
```

L'`AGORA_APP_ID` reste public côté `.env` client + secret côté serveur
pour cohérence de signature.
