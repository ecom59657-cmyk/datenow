import 'package:flutter/widgets.dart';

import '../../../../l10n/app_localizations.dart';
import 'legal_scaffold.dart';

/// Conditions d'utilisation — version FR / EN cohérente avec l'app
/// (matching live + dates vidéo 5 min + reveal post-date + abonnement
/// Premium optionnel). Le contenu est crédible juridiquement,
/// compatible App Store, et lisible par un utilisateur non-juriste.
class LegalTermsScreen extends StatelessWidget {
  const LegalTermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isFr = Localizations.localeOf(context).languageCode == 'fr';

    return LegalScaffold(
      title: l10n.termsTitle,
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
    'Acceptation des conditions',
    'En créant un compte sur DateNow ou en utilisant l\'application, vous '
        'acceptez intégralement les présentes Conditions d\'utilisation. '
        'Si vous n\'êtes pas d\'accord avec un seul de leurs termes, vous '
        'ne devez pas utiliser le service. Ces conditions forment un '
        'contrat entre vous et DateNow.'
  ),
  (
    'Comment fonctionne DateNow',
    'DateNow est une plateforme de rencontres en direct par vidéo. Nous '
        'mettons en relation des membres adultes, compatibles et '
        'simultanément en ligne, pour un date audio ou vidéo en direct '
        'd\'une durée fixe de 5 minutes. À la fin de chaque date, chacun '
        'des deux participants choisit indépendamment de continuer, '
        'd\'échanger les profils (« reveal ») ou de passer. Aucun '
        'échange n\'est forcé : il faut un accord mutuel pour qu\'une '
        'mise en relation se poursuive.'
  ),
  (
    'Compte et éligibilité',
    'Vous devez avoir 18 ans révolus pour créer un compte. Vous certifiez '
        'que les informations que vous fournissez (prénom, date de '
        'naissance, photos, préférences) sont exactes et vous appartiennent. '
        'Un seul compte par personne. Vous êtes responsable de la '
        'confidentialité de votre adresse e-mail et de toute activité '
        'effectuée depuis votre compte.'
  ),
  (
    'Comportement attendu',
    'DateNow repose sur le respect. Pendant un date ou une conversation, '
        'vous vous engagez à rester courtois, à ne pas tenir de propos '
        'haineux, sexistes, racistes, homophobes ou discriminatoires, à '
        'ne pas harceler une autre personne, à ne pas insister après un '
        'refus, et à ne pas tenter d\'extorquer une rencontre physique, '
        'des informations personnelles ou des moyens de paiement.'
  ),
  (
    'Contenu et usages interdits',
    'Sont strictement interdits : nudité, contenu sexuellement explicite, '
        'violence, contenu illégal, usurpation d\'identité (deepfake, '
        'photo d\'une autre personne, identité fictive), promotion ou '
        'sollicitation commerciale (escorting, services payants), spam, '
        'liens vers des sites tiers à caractère malveillant, et tout '
        'contenu mettant en scène des mineurs. Est également interdit '
        'tout enregistrement, capture d\'écran ou diffusion d\'un appel '
        'vidéo ou audio sans le consentement explicite et préalable du '
        'ou des autres participants. Toute infraction peut entraîner la '
        'suspension immédiate du compte sans préavis.'
  ),
  (
    'Modération, signalement et suspension',
    'Vous pouvez signaler à tout moment un profil, un message ou un '
        'comportement inapproprié depuis l\'écran post-date, depuis une '
        'conversation, ou depuis les réglages. Les signalements sont '
        'confidentiels et examinés par notre équipe de modération. Selon '
        'la gravité, nous pouvons avertir, suspendre temporairement ou '
        'supprimer définitivement un compte. Nous coopérons avec les '
        'autorités compétentes en cas d\'infraction grave.'
  ),
  (
    'Appels vidéo et reveal',
    'DateNow facilite la mise en relation par vidéo en direct mais ne '
        'peut pas garantir le comportement des autres utilisateurs. Vous '
        'restez seul responsable de vos décisions, échanges et rencontres '
        'éventuelles. Pendant un date, votre image est volontairement '
        'floutée par l\'application : seuls vos gestes et votre voix sont '
        'transmis. Les deux participants ne voient les photos l\'un de '
        'l\'autre qu\'après avoir accepté le reveal à la fin des 5 minutes. '
        'Cette mécanique est centrale au produit et ne peut être contournée.'
  ),
  (
    'Abonnement Premium et achats in-app',
    'Certaines fonctionnalités (dates illimités, filtres avancés, '
        'notifications prioritaires) nécessitent un abonnement Premium '
        'mensuel ou annuel facturé via Apple App Store ou Google Play. '
        'Le renouvellement est automatique jusqu\'à l\'annulation, '
        'gérable depuis les réglages de votre compte Apple ou Google. '
        'Aucun remboursement partiel n\'est pris en charge par DateNow : '
        'les demandes de remboursement passent par Apple ou Google '
        'selon leurs conditions.'
  ),
  (
    'Suppression et résiliation',
    'Vous pouvez supprimer votre compte à tout moment depuis Réglages → '
        '« Supprimer mon compte ». La suppression efface définitivement '
        'votre profil, vos photos, vos matchs, vos conversations et votre '
        'présence en quelques secondes. DateNow peut suspendre ou '
        'résilier votre compte sans préavis en cas de violation des '
        'présentes conditions ou de risque pour les autres utilisateurs. '
        'Aucun remboursement n\'est dû en cas de résiliation pour faute.'
  ),
  (
    'Limitation de responsabilité et contact',
    'Dans les limites autorisées par la loi, DateNow ne peut être tenu '
        'responsable d\'un dommage indirect, immatériel ou consécutif '
        'résultant de l\'utilisation du service, des comportements des '
        'autres utilisateurs ou d\'une interruption technique. Nous '
        'pouvons faire évoluer ces conditions ; vous serez informé dans '
        'l\'application au moins 14 jours avant l\'entrée en vigueur des '
        'changements substantiels. Les présentes conditions sont régies '
        'par le droit français. Pour toute question : '
        'support@datenow.app · questions juridiques : legal@datenow.app.'
  ),
];

// ---------------------------------------------------------------------------
// EN
// ---------------------------------------------------------------------------

const List<(String, String)> _enSections = [
  (
    'Acceptance of terms',
    'By creating an account on DateNow or by using the app, you fully '
        'accept these Terms of Use. If you disagree with any of them, do '
        'not use the service. These terms form a contract between you '
        'and DateNow.'
  ),
  (
    'How DateNow works',
    'DateNow is a live video dating platform. We connect adult members '
        'who are compatible and simultaneously online for a 5-minute '
        'live audio or video date. At the end of each date, both '
        'participants independently choose to continue, swap profiles '
        '(the "reveal"), or move on. No exchange is forced: a mutual '
        'agreement is required for any further interaction.'
  ),
  (
    'Account and eligibility',
    'You must be 18 or older to create an account. You certify that the '
        'information you provide (first name, birth date, photos, '
        'preferences) is accurate and is yours. One account per person. '
        'You are responsible for keeping your e-mail credentials secure '
        'and for any activity conducted through your account.'
  ),
  (
    'Expected behaviour',
    'DateNow runs on respect. During a date or a conversation you commit '
        'to staying courteous, never engaging in hateful, sexist, racist, '
        'homophobic or discriminatory speech, never harassing another '
        'person, never pressing a refusal, and never attempting to extract '
        'a physical meeting, personal information or payment.'
  ),
  (
    'Prohibited content and uses',
    'The following are strictly prohibited: nudity, sexually explicit '
        'content, violence, illegal content, impersonation (deepfake, '
        'someone else\'s photo, fake identity), commercial promotion or '
        'solicitation (escorting, paid services), spam, links to '
        'malicious third-party sites, and any content involving minors. '
        'Any recording, screenshot or broadcast of a video or audio call '
        'without the explicit and prior consent of the other '
        'participant(s) is also prohibited. Any infringement may lead to '
        'immediate account suspension without notice.'
  ),
  (
    'Moderation, reporting and suspension',
    'You can report a profile, a message or a behaviour at any time from '
        'the post-date screen, from a conversation, or from settings. '
        'Reports are confidential and reviewed by our moderation team. '
        'Depending on severity, we may warn, temporarily suspend or '
        'permanently delete an account. We cooperate with the relevant '
        'authorities in case of serious infringement.'
  ),
  (
    'Live video and reveal',
    'DateNow facilitates live video matchmaking but cannot guarantee '
        'the behaviour of other users. You remain solely responsible '
        'for your decisions, exchanges and any meetings that follow. '
        'During a date, your video feed is intentionally blurred by the '
        'app: only your gestures and your voice are transmitted. Both '
        'participants only see each other\'s photos after they have '
        'accepted the reveal at the end of the 5 minutes. This mechanic '
        'is core to the product and cannot be bypassed.'
  ),
  (
    'Premium subscription and in-app purchases',
    'Some features (unlimited dates, advanced filters, priority '
        'notifications) require a monthly or yearly Premium subscription '
        'billed via Apple App Store or Google Play. Renewal is automatic '
        'until cancellation, which you can manage from your Apple or '
        'Google account settings. DateNow does not handle partial refunds: '
        'refund requests go through Apple or Google under their own terms.'
  ),
  (
    'Suspension and termination',
    'You can delete your account at any time from Settings → "Delete my '
        'account". Deletion permanently wipes your profile, photos, '
        'matches, conversations and presence within seconds. DateNow may '
        'suspend or terminate your account without notice for any '
        'violation of these terms or any risk to other users. No refund '
        'is due in case of termination for misconduct.'
  ),
  (
    'Limitation of liability and contact',
    'To the extent permitted by law, DateNow cannot be held liable for '
        'any indirect, immaterial or consequential damage arising from '
        'the use of the service, from other users\' behaviour, or from a '
        'technical interruption. We may update these terms; you will be '
        'notified in-app at least 14 days before any substantial change '
        'takes effect. These terms are governed by French law. For any '
        'question: support@datenow.app · legal questions: '
        'legal@datenow.app.'
  ),
];
