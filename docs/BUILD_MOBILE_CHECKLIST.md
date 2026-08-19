# Checklist build mobile — DateNow (iOS / Android / TestFlight)

Préparer DateNow pour un **test réel sur téléphones physiques**. Cette
checklist ne change aucune logique métier — elle vérifie permissions,
configuration release et étapes de build.

État vérifié dans le repo au moment de la rédaction :

| Élément | Valeur actuelle | À adapter avant publication ? |
|---------|-----------------|-------------------------------|
| `version` (pubspec.yaml) | `0.1.0+1` | Incrémenter à chaque upload |
| iOS bundle id | `com.datenow.app` | Non — identifiant final |
| iOS `CFBundleDisplayName` | `DateNow` | Non |
| iOS deployment target | `15.1` | OK (requis par Agora) |
| Android `applicationId` / `namespace` | `com.datenow.app` | Non — identifiant final |
| Android `android:label` | `DateNow` | Non |
| Android signing release | `key.properties` (fallback debug) | Fournir le keystore — voir §6 |

---

## 1. Permissions iOS — `ios/Runner/Info.plist`

Présentes et rédigées en français, orientées utilisateur :

- ☑ `NSCameraUsageDescription` — caméra pour les dates vidéo + photo de profil
- ☑ `NSMicrophoneUsageDescription` — micro pendant les dates vidéo
- ☑ `NSPhotoLibraryUsageDescription` — accès photos pour la photo de profil

> Aucune mention technique (« Agora », « RTC »…) dans les textes : Apple
> rejette les descriptions vagues ou techniques en revue.

## 2. Permissions Android — `android/app/src/main/AndroidManifest.xml`

- ☑ `INTERNET`
- ☑ `ACCESS_NETWORK_STATE`
- ☑ `CAMERA`
- ☑ `RECORD_AUDIO`
- ☑ `MODIFY_AUDIO_SETTINGS`
- ☑ `WAKE_LOCK`, `BLUETOOTH_CONNECT` (confort Agora — micro Bluetooth)
- ☑ `uses-feature` caméra / micro en `required="false"` (pas de blocage Play Store)

## 3. Flux permissions Agora (vérifié — aucun changement de code)

- ☑ Caméra + micro demandées **avant** `AgoraClient.initialize()`
  (`agora_call_view.dart` → `_bootstrap`).
- ☑ Permission refusée → **aucun crash** : l'état passe à `permission_denied`
  et `_ErrorPanel` affiche un message clair non technique.
- ☑ Tous les codes d'erreur (`token_unavailable`, `token_failed`,
  `unauthenticated`, `web_unsupported`, échec moteur) sont mappés à un
  message utilisateur — le code brut n'est jamais affiché.
- ☑ Retour possible : pendant l'appel, le HUD de `CallScreen` garde le
  bouton retour + « Terminer le date » ; en pré-appel, `_ConnectingView`
  expose toujours « Annuler ».

**Test manuel à faire sur device :** refuser la caméra au 1er lancement →
vérifier message propre + sortie possible, sans crash.

## 4. Configuration release (vérifié)

- ☑ **Routes debug** (`/debug-matching`, `/debug-datenow`) enregistrées
  uniquement si `kDebugMode` → absentes en release, **même en deep link**.
- ☑ Tuile « Debug · DateNow » dans Réglages gated `if (kDebugMode)`.
- ☑ `AppLogger` gated `kDebugMode` → **aucun log en release**.
- ☑ Token Agora : seuls `généré oui/non`, `uid`, `expiration` exposés au
  Debug — **jamais la chaîne du token**.
- ☑ `AGORA_APP_CERTIFICATE` reste **côté serveur** (Edge Function). Le
  client ne reçoit qu'un token court signé + l'`AGORA_APP_ID` (public).
- ☑ Émission de token via l'Edge Function `generate-agora-token`.

**À ne pas committer :** `.env` (clés Supabase). Vérifier qu'il est bien
dans `.gitignore` et que l'environnement de build le fournit.

---

## 5. Build iOS → TestFlight

### Prérequis
- ☐ Xcode à jour + compte Apple Developer payant (99 $/an).
- ☑ Bundle id défini : **`com.datenow.app`** (Runner, configs Debug /
  Release / Profile). RunnerTests : `com.datenow.app.RunnerTests`.
- ☐ App créée dans **App Store Connect** avec le bundle id `com.datenow.app`.
- ☐ Signing : *Automatically manage signing* + votre Team sélectionnée
  (provisioning géré par Xcode).
- ☑ Nom affiché : **DateNow** (`CFBundleDisplayName`).
- ☑ Deployment target = **15.1** (requis par Agora).

### Étapes
```bash
flutter clean
flutter pub get
cd ios && pod install && cd ..
flutter build ipa --release
```
Puis :
- ☐ Ouvrir `build/ios/archive/Runner.xcarchive` dans Xcode
  (*Window → Organizer*) **ou** uploader directement :
```bash
xcrun altool --upload-app -f build/ios/ipa/*.ipa \
  -t ios -u <apple-id> -p <app-specific-password>
```
  (alternative moderne : `xcrun notarytool` / *Transporter.app*).
- ☐ Attendre le traitement dans App Store Connect → onglet TestFlight.
- ☐ Ajouter les testeurs internes, renseigner les notes de test.

### Résultat attendu
Build visible dans TestFlight au statut *Ready to Test*, installable via
l'app TestFlight sur l'iPhone du testeur.

---

## 6. Build Android (device réel / AAB)

### Prérequis
- ☑ `applicationId` + `namespace` = **`com.datenow.app`**
  (`android/app/build.gradle.kts`). Package Kotlin `MainActivity`
  aligné : `com/datenow/app/MainActivity.kt`.
- ☑ Nom affiché : **DateNow** (`android:label`).
- ☐ `minSdk` : Agora exige **21+**. Le projet utilise `flutter.minSdkVersion`
  (≥ 21 sur Flutter récent) — `flutter build apk` échoue sinon. Forcer
  `minSdk = 21` si besoin.
- ☐ Keystore release créé + `android/key.properties` rempli (voir
  *Procédure keystore* ci-dessous).

### Procédure keystore Android (à faire une fois)

1. Générer le keystore (hors du repo, ex. dans `~/`) :
   ```bash
   keytool -genkey -v -keystore ~/datenow-release.jks \
     -keyalg RSA -keysize 2048 -validity 10000 -alias datenow
   ```
2. Copier le template et le remplir :
   ```bash
   cp android/key.properties.example android/key.properties
   ```
   Renseigner `storeFile` (chemin absolu vers le `.jks`), `storePassword`,
   `keyAlias`, `keyPassword`.
3. C'est tout : `build.gradle.kts` lit `key.properties` automatiquement et
   signe le build release avec ce keystore.

> **Ne jamais committer** `android/key.properties` ni le fichier `.jks` :
> les deux sont déjà couverts par `.gitignore`. Sans `key.properties`, le
> build release retombe sur les clés debug (sideload uniquement).
> Sauvegarder le `.jks` ailleurs — le perdre rend impossible toute mise à
> jour de l'app sur le Play Store.

### Étapes
```bash
flutter clean
flutter pub get
flutter build apk --release        # APK — sideload direct sur device
# ou
flutter build appbundle --release  # AAB — pour le Play Store
```
- ☐ Installer l'APK : `flutter install` ou
  `adb install build/app/outputs/flutter-apk/app-release.apk`.
- ☐ Tester sur un device Android physique (l'émulateur n'a pas de vraie
  caméra/micro fiable pour Agora).

### Résultat attendu
APK installé, app qui démarre, permissions caméra/micro demandées au
1er date, vidéo Agora fonctionnelle.

---

## 7. Commandes utiles

```bash
flutter doctor -v                      # diagnostic environnement
flutter devices                        # devices/simulateurs connectés
flutter run --release -d <device-id>   # lancer un build release sur device
flutter build ipa --release            # archive iOS
flutter build apk --release            # APK Android
flutter build appbundle --release      # AAB Android
cd ios && pod install && cd ..         # (re)résoudre les pods iOS
flutter clean                          # purge build/ + caches
```

## 8. Erreurs fréquentes

| Symptôme | Cause probable | Solution |
|----------|----------------|----------|
| `pod install` échoue | CocoaPods désynchronisé | `cd ios && pod repo update && pod install` |
| Upload TestFlight rejeté « bundle id » | bundle id placeholder / non enregistré | Créer l'app dans App Store Connect avec le bon id |
| `IPHONEOS_DEPLOYMENT_TARGET` trop bas | pod exige ≥ 15.1 | Garder 15.1 (Runner + Podfile) |
| Écran noir au lancement de l'appel | permission caméra refusée | Vérifier `_ErrorPanel` s'affiche — réautoriser dans Réglages |
| Vidéo Agora vide | token non émis / Edge Function KO | Vérifier `generate-agora-token` déployée + secrets |
| Android : build échoue `minSdk` | Agora exige 21+ | Forcer `minSdk = 21` |
| `flutter run` sans fil ne s'attache pas | mDNS / « Réseau local » iOS | Brancher en USB ou autoriser « Réseau local » |
| App pèse lourd / lent en debug | testé en debug | Toujours tester en `--release` |

## 9. Checklist finale avant de partager à un testeur

- ☐ `flutter analyze` sans erreur.
- ☐ Build lancé en **release** (`--release`), pas en debug.
- ☑ Bundle id / applicationId définitifs : `com.datenow.app` (plus de `com.example`).
- ☐ Keystore release fourni (`android/key.properties`) si build Play Store.
- ☐ Numéro de version (`pubspec.yaml`) incrémenté.
- ☐ `.env` **non committé** ; clés Supabase fournies à l'environnement de build.
- ☐ Aucune route ni tuile debug visible en release (vérifié §4).
- ☐ Edge Function `generate-agora-token` déployée + secrets `AGORA_APP_ID`
      / `AGORA_APP_CERTIFICATE` configurés.
- ☐ Migrations Supabase à jour (`supabase db push`).
- ☐ Test sur **2 devices physiques** : permissions, date vidéo, blur,
      reveal — voir `docs/TEST_PROTOCOL_MVP.md`.
- ☐ Refus de permission testé → message propre, pas de crash.

---

## Tests SQL en local (sans Docker)

`flutter test` prouve que l'app n'envoie jamais une mauvaise valeur. Il ne
prouve pas que la base la refuserait, ni que la politique de lecture cache
bien ce qu'elle prétend cacher — ce sont des affirmations sur Postgres, et
seul Postgres y répond.

```bash
./scripts/test_user_background_sql.sh     # 16 contrôles, ~10 s
```

Le script monte un cluster Postgres jetable (`initdb` dans un dossier
temporaire, écoute sur 127.0.0.1:55432, supprimé à la sortie), y applique la
migration **telle quelle**, puis vérifie que les valeurs inconnues sont
refusées, qu'une personne ne peut ni écrire ni inventer la ligne d'une autre,
et qu'un blocage coupe la lecture dans les deux sens.

Requiert `brew install postgresql@17`. Aucun Docker.

C'est le harnais qui aurait attrapé l'erreur de syntaxe `ENABL` avant de la
coller dans l'éditeur Supabase.
