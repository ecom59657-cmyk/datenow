import 'package:flutter/widgets.dart';

import '../../../../l10n/app_localizations.dart';
import 'legal_document_screen.dart';

/// Politique de confidentialité — version FR / EN structurée autour des
/// exigences RGPD (base légale, droits du sujet, transferts, conservation)
/// et adaptée à un service de visio en direct (Agora) + matching live.
///
/// Le contenu cite explicitement Supabase (UE) et Agora (US) comme
/// sous-traitants, et précise que les flux vidéo / audio ne sont jamais
/// enregistrés — point critique pour la confiance utilisateur.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isFr = Localizations.localeOf(context).languageCode == 'fr';

    final sections = isFr ? _frSections : _enSections;

    return LegalDocumentScreen(
      title: l10n.privacyPolicyTitle,
      lastUpdated: isFr ? '29 mai 2026' : 'May 29, 2026',
      sections: sections,
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
        'préférences d\'application, et des données techniques minimales '
        '(modèle d\'appareil, version d\'OS, identifiants techniques '
        'éphémères, logs d\'erreur anonymisés). Nous ne collectons '
        'aucune donnée de localisation précise sans votre consentement '
        'explicite via les réglages iOS.'
  ),
  (
    'Base légale du traitement (RGPD art. 6)',
    'Vos données sont traitées sur la base de votre consentement (création '
        'de compte et utilisation du matching), de l\'exécution du '
        'contrat qui vous lie à DateNow (mise en relation, dates en '
        'direct, conversations), et de nos intérêts légitimes (sécurité '
        'du service, modération, prévention de la fraude). Vous pouvez '
        'retirer votre consentement à tout moment en supprimant votre '
        'compte.'
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
    'Caméra et microphone (visio Agora)',
    'Pendant un date vidéo en direct, votre caméra et votre microphone '
        'sont activés via Agora.io, notre fournisseur de visio. Le flux '
        'transite en pair-à-pair (P2P) ou via les serveurs Agora selon '
        'votre connexion. Aucun flux vidéo ou audio n\'est enregistré, '
        'stocké ou archivé, ni par DateNow, ni par Agora. La caméra est '
        'volontairement floutée par l\'application pendant tout le date.'
  ),
  (
    'Photos privées et reveal',
    'Vos photos sont stockées de façon privée et chiffrée au repos sur '
        'notre prestataire d\'hébergement Supabase, dans un bucket non '
        'public. Elles ne sont visibles par un autre utilisateur '
        'qu\'après un reveal mutuel (les deux personnes ont accepté à '
        'la fin d\'un date de 5 minutes). Aucun tiers (publicitaire, '
        'partenaire) n\'a accès à vos photos.'
  ),
  (
    'Sous-traitants et transferts internationaux',
    'Nous utilisons : Supabase (hébergement base de données et '
        'authentification, région EU-West) ; Agora.io (signalisation et '
        'transit visio, infrastructure mondiale) ; Apple Push Notification '
        'service (notifications iOS). Les transferts hors UE éventuels '
        'sont encadrés par des clauses contractuelles types (CCT) '
        'conformes à la décision 2021/914 de la Commission européenne.'
  ),
  (
    'Cookies et identifiants techniques',
    'L\'application iOS n\'utilise pas de cookies au sens web. Nous '
        'utilisons un identifiant technique chiffré (Supabase JWT) lié à '
        'votre session pour authentifier vos appels API. Cet identifiant '
        'est rotatif, lié à votre appareil, et ne contient aucune donnée '
        'directement identifiante.'
  ),
  (
    'Signalement et modération',
    'Vous pouvez signaler à tout moment un profil ou un comportement '
        'inapproprié. Les signalements (catégorie + description '
        'optionnelle) sont stockés de façon confidentielle et examinés '
        'par notre équipe de modération. Un utilisateur signalé peut être '
        'averti, suspendu temporairement ou supprimé. Les données du '
        'signalement sont conservées jusqu\'à 12 mois pour assurer le '
        'suivi des récidives.'
  ),
  (
    'Protection des mineurs',
    'DateNow est strictement réservé aux personnes de 18 ans et plus. '
        'Nous vérifions l\'âge déclaré au moment de l\'inscription. Tout '
        'profil identifié comme appartenant à un mineur est suspendu '
        'immédiatement, ses données sont effacées dans les meilleurs '
        'délais, et le cas est documenté à des fins de prévention. Vous '
        'pouvez signaler un profil suspect via la catégorie « Profil '
        'semble mineur ».'
  ),
  (
    'Vos droits (RGPD)',
    'Vous disposez d\'un droit d\'accès, de rectification, d\'effacement, '
        'de portabilité, de limitation et d\'opposition au traitement de '
        'vos données. Vous pouvez exercer ces droits depuis Réglages → '
        '« Modifier mon profil » et « Supprimer mon compte », ou par '
        'e-mail à privacy@datenow.app. Vous pouvez également introduire '
        'une réclamation auprès de la CNIL (www.cnil.fr).'
  ),
  (
    'Sécurité et conservation',
    'Vos données sont chiffrées en transit (TLS 1.3) et au repos. Les '
        'mots de passe sont hachés (Supabase Auth) ; les jetons d\'accès '
        'Agora sont signés à la demande, valides 15 minutes, et liés à '
        'votre identifiant pour empêcher tout usage hors session. Vos '
        'données sont conservées tant que votre compte est actif. Après '
        'suppression, elles sont effacées immédiatement, sauf obligation '
        'légale (logs de sécurité conservés au maximum 30 jours).'
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
    'To run DateNow we collect: your e-mail address, profile information '
        '(first name, birth date, gender, orientation, matching '
        'preferences), your photos, your in-app preferences, and minimal '
        'technical data (device model, OS version, ephemeral technical '
        'identifiers, anonymised error logs). We do not collect precise '
        'location data without your explicit consent through iOS settings.'
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
    'Camera and microphone (Agora video)',
    'During a live video date, your camera and microphone are enabled '
        'via Agora.io, our video provider. The stream is peer-to-peer '
        '(P2P) or relayed through Agora\'s servers depending on your '
        'connection. No video or audio stream is recorded, stored or '
        'archived, by DateNow or by Agora. The camera is intentionally '
        'blurred by the app for the entire date.'
  ),
  (
    'Private photos and reveal',
    'Your photos are stored privately and encrypted at rest on our '
        'hosting provider Supabase, in a non-public bucket. They are '
        'only visible to another user after a mutual reveal (both people '
        'accepted at the end of a 5-minute date). No third party '
        '(advertiser, partner) has access to your photos.'
  ),
  (
    'Sub-processors and international transfers',
    'We use: Supabase (database hosting and authentication, EU-West '
        'region); Agora.io (video signalling and transit, worldwide '
        'infrastructure); Apple Push Notification service (iOS '
        'notifications). Any transfers outside the EU are governed by '
        'Standard Contractual Clauses (SCCs) compliant with European '
        'Commission decision 2021/914.'
  ),
  (
    'Cookies and technical identifiers',
    'The iOS app does not use cookies in the web sense. We use an '
        'encrypted technical identifier (Supabase JWT) tied to your '
        'session to authenticate your API calls. This identifier is '
        'rotated, bound to your device, and contains no directly '
        'identifying data.'
  ),
  (
    'Reporting and moderation',
    'You can report a profile or behaviour at any time. Reports '
        '(category + optional description) are stored confidentially and '
        'reviewed by our moderation team. A reported user may be warned, '
        'temporarily suspended or deleted. Report data is kept for up to '
        '12 months to support repeat-offender tracking.'
  ),
  (
    'Protection of minors',
    'DateNow is strictly reserved for people 18 and older. We verify the '
        'declared age at registration. Any profile identified as '
        'belonging to a minor is suspended immediately, its data is '
        'wiped as soon as possible, and the case is documented for '
        'prevention purposes. You can report a suspicious profile via '
        'the "Profile appears to be a minor" category.'
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
    'Security and retention',
    'Your data is encrypted in transit (TLS 1.3) and at rest. Passwords '
        'are hashed (Supabase Auth); Agora access tokens are signed on '
        'demand, valid for 15 minutes, and bound to your identifier so '
        'they cannot be reused outside your session. Your data is '
        'retained as long as your account is active. After deletion, it '
        'is wiped immediately, except where the law requires otherwise '
        '(security logs kept for a maximum of 30 days).'
  ),
  (
    'Contact',
    'Privacy questions or to exercise your rights: privacy@datenow.app. '
        'General support: support@datenow.app. Data Protection Officer '
        '(DPO): dpo@datenow.app. We commit to responding within 30 days '
        'as required by GDPR article 12.'
  ),
];
