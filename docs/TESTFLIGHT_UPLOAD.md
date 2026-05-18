# Upload TestFlight — DateNow

Procédure pour publier une build DateNow sur TestFlight et envoyer un
lien d'installation à quelques amis testeurs (iPhone).

## État vérifié du projet

| Élément | Valeur | OK |
|---------|--------|----|
| Bundle ID | `com.datenow.app` | ☑ |
| Display Name | `DateNow` (`CFBundleDisplayName`) | ☑ |
| Signing | Automatique, team Xcode `LUDW9MH7BS` | ☑ |
| iOS minimum | `15.1` (`IPHONEOS_DEPLOYMENT_TARGET`) | ☑ |
| Permissions | caméra / micro / photos — textes FR orientés utilisateur | ☑ |
| Version | `0.1.0+1` (`pubspec.yaml`) — **à incrémenter à chaque upload** | ⚠ |
| Routes debug en release | absentes (`if (kDebugMode)`) | ☑ |
| Overlay OBS en release | non monté (`!kDebugMode` → child brut) | ☑ |
| Token Agora | jamais affiché ; certificat 100 % serveur | ☑ |
| Émission token | via Edge Function `generate-agora-token` | ☑ |
| Build release | `flutter build ios --release` → `✓ Built Runner.app` | ☑ |

---

## 1. Checklist AVANT upload

À cocher avant de lancer l'archive Xcode :

- ☐ Supabase remote joignable (le projet pointe sur le bon environnement).
- ☐ Migrations appliquées sur le remote — `supabase db push` dit « up to date ».
- ☐ Edge Function déployée — `supabase functions list` montre `generate-agora-token`.
- ☐ Secrets Agora présents — `supabase secrets list` montre `AGORA_APP_ID`
      et `AGORA_APP_CERTIFICATE`.
- ☐ Test local 2 iPhones effectué — scénario `docs/SMOKE_TEST_FINAL.md` §3 OK.
- ☐ Aucune surface debug en release — vérifié par `flutter test`
      (`test/release_safety_test.dart`) + build release.
- ☐ Numéro de build incrémenté dans `pubspec.yaml` (voir §2).
- ☐ `bash scripts/pre_real_device_test.sh` → tout vert.

---

## 2. Incrémenter la version

TestFlight **refuse** un build dont le numéro existe déjà. Avant chaque
upload, incrémenter le nombre après le `+` dans `pubspec.yaml` :

```yaml
# version: nom_de_version+numéro_de_build
version: 0.1.0+1   →   0.1.0+2   →   0.1.0+3 …
```

Le `name` (`0.1.0`) peut rester ; seul le `+build` doit être unique.

---

## 3. Build de l'archive (Xcode)

```bash
# Repartir propre
flutter clean
flutter pub get
flutter build ios --release        # build release codesignée
open ios/Runner.xcworkspace        # TOUJOURS le .xcworkspace, pas le .xcodeproj
```

Dans Xcode :

1. En haut, sélectionner le scheme **Runner** et la cible
   **Any iOS Device (arm64)** (pas un simulateur — l'archive l'exige).
2. Onglet **Signing & Capabilities** du target *Runner* : vérifier
   *Automatically manage signing* coché + Team = `LUDW9MH7BS`. Xcode
   génère le profil de distribution tout seul.
3. Menu **Product → Archive**. Attendre la fin du build.
4. La fenêtre **Organizer** s'ouvre sur l'archive fraîche.

---

## 4. Distribution → App Store Connect

Dans l'Organizer :

1. Sélectionner l'archive → **Distribute App**.
2. Choisir **App Store Connect** → **Upload**.
3. Laisser les options par défaut (gestion automatique de la signature,
   symboles inclus) → **Next** → **Upload**.
4. Attendre « Upload Successful ».

> Pré-requis App Store Connect : une app doit exister avec le bundle id
> `com.datenow.app`. Si ce n'est pas le cas → appstoreconnect.apple.com →
> *Apps* → *+* → *New App* (plateforme iOS, bundle id `com.datenow.app`).

Après l'upload, le build apparaît dans **App Store Connect → DateNow →
TestFlight** au statut *Processing* (~5–15 min), puis *Ready to Submit*.

---

## 5. TestFlight — ajouter des testeurs

### Testeurs internes (membres de l'équipe Apple Developer)
- App Store Connect → TestFlight → **Internal Testing**.
- Créer un groupe, ajouter les comptes (jusqu'à 100).
- Accès **immédiat** dès la fin du *Processing*, sans revue Apple.

### Testeurs externes (vos amis)
- TestFlight → **External Testing** → créer un groupe (ex. « Amis »).
- Ajouter les testeurs par e-mail, **ou** activer le **lien public**.
- Renseigner les infos de test obligatoires : description, e-mail de
  contact, « What to Test ».
- Le **premier** build destiné aux externes passe une **revue Apple
  Beta** (généralement < 24 h). Les builds suivants du même groupe sont
  souvent acceptés sans nouvelle revue.

### Lien public TestFlight
- Dans le groupe externe → activer **Public Link**.
- App Store Connect génère une URL `https://testflight.apple.com/join/XXXXXXXX`.
- Envoyer ce lien aux amis : ils installent l'app **TestFlight** depuis
  l'App Store, ouvrent le lien, et installent DateNow.

---

## 6. Notes pour les testeurs

À transmettre avec le lien :

- Installer d'abord l'app **TestFlight** (App Store), puis ouvrir le lien.
- DateNow demande caméra + micro au premier date vidéo — accepter.
- Un date se fait à **2 personnes en même temps** : se coordonner pour
  lancer la recherche simultanément.
- La build expire après 90 jours — un nouvel upload sera nécessaire.

---

## Erreurs fréquentes

| Symptôme | Cause | Solution |
|----------|-------|----------|
| Upload refusé « build number already used » | `+build` non incrémenté | Incrémenter `pubspec.yaml` (§2) |
| « No account / team » à l'archive | team non sélectionnée | Signing & Capabilities → Team `LUDW9MH7BS` |
| Archive grisée dans Product | simulateur sélectionné | Choisir *Any iOS Device (arm64)* |
| App rejetée en Beta Review | infos de test manquantes | Remplir description + contact + What to Test |
| Build bloqué en *Processing* | traitement Apple en cours | Attendre 15 min, rafraîchir |
