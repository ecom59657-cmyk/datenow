import 'package:flutter/widgets.dart';

import '../../../../l10n/app_localizations.dart';
import 'legal_scaffold.dart';

/// Politique de confidentialité — version FR / EN structurée autour des
/// exigences RGPD (base légale, droits du sujet, transferts, conservation)
/// et adaptée à un service de visio en direct (Agora) + matching live.
///
/// Le contenu cite explicitement Supabase (UE) et Agora comme
/// sous-traitants, précise que les flux vidéo / audio ne sont jamais
/// enregistrés, et détaille séparément l'authentification (Apple / Google
/// / Email OTP) et la géolocalisation approximative.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isFr = Localizations.localeOf(context).languageCode == 'fr';

    return LegalScaffold(
      title: l10n.privacyPolicyTitle,
      lastUpdated: isFr ? '29 mai 2026' : 'May 29, 2026',
      sections: isFr ? _frSections : _enSections,
    );
  }
}

// ---------------------------------------------------------------------------
// FR
// ---------------------------------------------------------------------------

const List<(String, String)> _frSections = [
  (
    'Données que nous collectons',
    'Pour faire fonctionner DateNow, nous collectons : votre adresse '
        'e-mail, vos informations de profil (prénom, date de naissance, '
        'genre, orientation, préférences de matching), vos photos, vos '
        'messages échangés avec d\'autres utilisateurs, votre '
        'localisation approximative (au niveau ville / région, jamais '
        'l\'adresse précise), vos préférences d\'application, et des '
        'données techniques minimales (modèle d\'appareil, version d\'OS, '
        'identifiants techniques éphémères, logs d\'erreur anonymisés).'
  ),
  (
    'Authentification',
    'L\'inscription et la reconnexion à DateNow se font via Sign in with '
        'Apple, Sign in with Google ou un code à usage unique (OTP) '
        'envoyé par e-mail, géré par Supabase Auth. Aucun mot de passe '
        'persistant n\'est conservé en clair. Pour Apple et Google, nous '
        'ne recevons que les informations strictement nécessaires '
        '(identifiant technique + e-mail relais le cas échéant) — nous '
        'ne lisons pas vos contacts, photos ou agenda.'
  ),
  (
    'Base légale du traitement (RGPD art. 6)',
    'Vos données sont traitées sur la base de votre consentement '
        '(création de compte et utilisation du matching), de '
        'l\'exécution du contrat qui vous lie à DateNow (mise en '
        'relation, dates en direct, conversations), et de nos intérêts '
        'légitimes (sécurité du service, modération, prévention de la '
        'fraude). Vous pouvez retirer votre consentement à tout moment '
        'en supprimant votre compte.'
  ),
  (
    'Comment nous utilisons vos données',
    'Pour vous proposer des matchs pertinents, sécuriser votre compte, '
        'détecter et traiter les signalements, améliorer la qualité du '
        'matching, et vous envoyer uniquement les notifications que vous '
        'avez activées. Nous ne créons pas de profil publicitaire à '
        'partir de vos données. Aucun ciblage publicitaire n\'est effectué.'
  ),
  (
    'Caméra, microphone et appels vidéo',
    'Pendant un date en direct, votre caméra et votre microphone sont '
        'activés via Agora.io, notre fournisseur de visio. Le flux '
        'transite en pair-à-pair (P2P) ou via les serveurs Agora selon '
        'votre connexion. Aucun flux vidéo ou audio n\'est enregistré, '
        'stocké ou archivé, ni par DateNow, ni par Agora. La caméra est '
        'volontairement floutée par l\'application pendant tout le date.'
  ),
  (
    'Géolocalisation',
    'Nous utilisons votre localisation approximative (au niveau ville / '
        'région, dérivée de l\'adresse IP ou d\'une autorisation iOS '
        '« quand l\'app est utilisée ») pour améliorer la pertinence des '
        'suggestions et respecter le rayon que vous avez choisi. Nous ne '
        'partageons jamais votre position précise avec un autre '
        'utilisateur ni avec un tiers. Vous pouvez désactiver l\'accès '
        'à votre localisation à tout moment depuis les réglages iOS.'
  ),
  (
    'Photos privées et reveal',
    'Vos photos sont stockées de façon privée et chiffrées au repos '
        'chez Supabase, dans un bucket non public. Elles ne sont '
        'visibles par un autre utilisateur qu\'après un reveal mutuel '
        '(les deux personnes ont accepté à la fin d\'un date de '
        '5 minutes). Aucun tiers (publicitaire, partenaire) n\'a accès '
        'à vos photos.'
  ),
  (
    'Hébergement, sous-traitants et partage',
    'Nous utilisons : Supabase (hébergement base de données et '
        'authentification, région EU-West) ; Agora.io (signalisation et '
        'transit visio, infrastructure mondiale) ; Apple Push Notification '
        'service (notifications iOS). Les transferts hors UE éventuels '
        'sont encadrés par des clauses contractuelles types (CCT) '
        'conformes à la décision 2021/914 de la Commission européenne. '
        'Vos données ne sont jamais vendues à des tiers ; elles ne sont '
        'partagées qu\'avec ces sous-traitants strictement nécessaires '
        'au fonctionnement du service.'
  ),
  (
    'Sécurité du compte',
    'Vos données sont chiffrées en transit (TLS 1.3) et au repos. Les '
        'identifiants de session sont hachés et signés (Supabase JWT) ; '
        'les jetons d\'accès Agora sont signés à la demande, valides '
        '15 minutes, et liés à votre identifiant pour empêcher tout '
        'usage hors session. Nous appliquons des mesures techniques et '
        'organisationnelles raisonnables (revues de code, audits '
        'd\'accès, principe du moindre privilège).'
  ),
  (
    'Conservation et suppression',
    'Vos données sont conservées tant que votre compte est actif. Vous '
        'pouvez supprimer votre compte à tout moment depuis Réglages → '
        '« Supprimer mon compte » : profil, photos, matchs, conversations '
        'et présence sont effacés en quelques secondes. Nous conservons '
        'au maximum 30 jours certains logs de sécurité strictement '
        'nécessaires à la lutte contre la fraude.'
  ),
  (
    'Vos droits (RGPD)',
    'Vous disposez d\'un droit d\'accès, de rectification, d\'effacement, '
        'de portabilité, de limitation et d\'opposition au traitement de '
        'vos données. Vous pouvez exercer ces droits depuis Réglages → '
        '« Modifier mon profil » et « Supprimer mon compte », ou par '
        'e-mail à privacy@datenow.app. Vous pouvez également introduire '
        'une réclamation auprès de la CNIL (www.cnil.fr) ou de toute '
        'autorité de contrôle européenne compétente.'
  ),
  (
    'Contact',
    'Questions confidentialité ou exercice de vos droits : '
        'privacy@datenow.app. Support général : support@datenow.app. '
        'Délégué à la protection des données (DPO) : dpo@datenow.app. '
        'Nous nous engageons à répondre sous 30 jours conformément à '
        'l\'article 12 du RGPD.'
  ),
];

// ---------------------------------------------------------------------------
// EN
// ---------------------------------------------------------------------------

const List<(String, String)> _enSections = [
  (
    'Data we collect',
    'To run DateNow we collect: your e-mail address, profile '
        'information (first name, birth date, gender, orientation, '
        'matching preferences), your photos, the messages you exchange '
        'with other users, your approximate location (city / region '
        'level only, never your exact address), your in-app preferences, '
        'and minimal technical data (device model, OS version, ephemeral '
        'technical identifiers, anonymised error logs).'
  ),
  (
    'Authentication',
    'Signing up and signing back in to DateNow happens through Sign in '
        'with Apple, Sign in with Google, or a one-time code (OTP) sent '
        'by e-mail through Supabase Auth. No persistent password is '
        'stored in clear. For Apple and Google, we only receive the '
        'strictly necessary information (technical identifier + relay '
        'e-mail when applicable) — we do not read your contacts, photos, '
        'or calendar.'
  ),
  (
    'Legal basis for processing (GDPR art. 6)',
    'Your data is processed on the basis of your consent (account '
        'creation and use of matching), the performance of the contract '
        'between you and DateNow (matchmaking, live dates, conversations), '
        'and our legitimate interests (service security, moderation, '
        'fraud prevention). You may withdraw your consent at any time by '
        'deleting your account.'
  ),
  (
    'How we use your data',
    'To propose relevant matches, secure your account, detect and '
        'process reports, improve matching quality, and send only the '
        'notifications you have opted in to. We do not build any '
        'advertising profile from your data. No ad targeting takes place.'
  ),
  (
    'Camera, microphone and live video',
    'During a live date, your camera and microphone are enabled via '
        'Agora.io, our video provider. The stream is peer-to-peer (P2P) '
        'or relayed through Agora\'s servers depending on your '
        'connection. No video or audio stream is recorded, stored or '
        'archived, by DateNow or by Agora. The camera is intentionally '
        'blurred by the app for the entire date.'
  ),
  (
    'Location',
    'We use your approximate location (city / region level, derived '
        'either from your IP address or from an iOS "while the app is in '
        'use" permission) to improve suggestion relevance and respect '
        'the radius you chose. We never share your precise location '
        'with another user or any third party. You can disable location '
        'access at any time from iOS settings.'
  ),
  (
    'Private photos and reveal',
    'Your photos are stored privately and encrypted at rest on '
        'Supabase, in a non-public bucket. They are only visible to '
        'another user after a mutual reveal (both people accepted at '
        'the end of a 5-minute date). No third party (advertiser, '
        'partner) has access to your photos.'
  ),
  (
    'Hosting, sub-processors and sharing',
    'We use: Supabase (database hosting and authentication, EU-West '
        'region); Agora.io (video signalling and transit, worldwide '
        'infrastructure); Apple Push Notification service (iOS '
        'notifications). Any transfers outside the EU are governed by '
        'Standard Contractual Clauses (SCCs) compliant with European '
        'Commission decision 2021/914. Your data is never sold to third '
        'parties; it is only shared with these sub-processors strictly '
        'necessary to operate the service.'
  ),
  (
    'Account security',
    'Your data is encrypted in transit (TLS 1.3) and at rest. Session '
        'identifiers are hashed and signed (Supabase JWT); Agora access '
        'tokens are signed on demand, valid for 15 minutes, and bound '
        'to your identifier so they cannot be reused outside your '
        'session. We apply reasonable technical and organisational '
        'measures (code reviews, access audits, least-privilege '
        'principle).'
  ),
  (
    'Retention and deletion',
    'Your data is retained as long as your account is active. You can '
        'delete your account at any time from Settings → "Delete my '
        'account": profile, photos, matches, conversations and presence '
        'are wiped within seconds. We retain certain security logs for '
        'a maximum of 30 days, strictly for fraud prevention purposes.'
  ),
  (
    'Your rights (GDPR)',
    'You have a right of access, rectification, erasure, portability, '
        'restriction and objection regarding the processing of your '
        'data. You can exercise these rights from Settings → "Edit my '
        'profile" and "Delete my account", or by e-mail at '
        'privacy@datenow.app. You may also lodge a complaint with the '
        'French Data Protection Authority (CNIL, www.cnil.fr) or any '
        'other competent EU supervisory authority.'
  ),
  (
    'Contact',
    'Privacy questions or to exercise your rights: privacy@datenow.app. '
        'General support: support@datenow.app. Data Protection Officer '
        '(DPO): dpo@datenow.app. We commit to responding within 30 days '
        'as required by GDPR article 12.'
  ),
];
