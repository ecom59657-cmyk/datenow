import 'package:flutter/widgets.dart';

import '../../../../l10n/app_localizations.dart';
import 'legal_document_screen.dart';

/// Static placeholder content for the Privacy Policy. Real copy lives with
/// legal — this MVP build ships generic but plausible text so the screen
/// is exploitable end-to-end.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isFr = Localizations.localeOf(context).languageCode == 'fr';

    final sections = isFr
        ? const <(String, String)>[
            (
              'Ce que nous collectons',
              'Votre adresse e-mail, vos informations de profil (prénom, '
                  'date de naissance, genre, orientation, préférences), vos '
                  'photos, vos préférences d\'application, et les données '
                  'techniques (modèle de téléphone, version OS, logs '
                  'd\'erreur anonymisés) nécessaires au bon fonctionnement '
                  'du service.'
            ),
            (
              'Pourquoi nous les utilisons',
              'Pour vous proposer des matchs pertinents, sécuriser votre '
                  'compte, traiter les signalements, améliorer la qualité '
                  'du matching, et vous envoyer les notifications que vous '
                  'avez activées.'
            ),
            (
              'Caméra et micro (visio Agora)',
              'Pendant un date vidéo en direct, votre caméra et votre micro '
                  'sont activés via Agora.io, notre prestataire de visio. '
                  'Le flux vidéo et audio n\'est jamais enregistré. La '
                  'caméra est floutée pendant tout le date — le flou ne '
                  'tombe qu\'au moment du reveal post-date.'
            ),
            (
              'Photos',
              'Vos photos sont stockées de façon privée sur notre serveur '
                  'Supabase et ne sont visibles par un autre utilisateur '
                  'qu\'après un match mutuel (les deux personnes ont validé '
                  'le reveal post-date).'
            ),
            (
              'Hébergement et prestataires',
              'Nous utilisons Supabase pour l\'hébergement de la base de '
                  'données et l\'authentification, et Agora.io pour la visio. '
                  'Aucune de vos données n\'est vendue ni partagée à des fins '
                  'publicitaires.'
            ),
            (
              'Signalement et modération',
              'Vous pouvez signaler tout profil ou comportement '
                  'inapproprié depuis l\'écran post-date ou la conversation. '
                  'Les signalements sont confidentiels et examinés par notre '
                  'équipe. Un utilisateur signalé peut être suspendu sans '
                  'préavis.'
            ),
            (
              'Protection des mineurs',
              'DateNow est strictement réservé aux personnes de 18 ans et '
                  'plus. Tout profil identifié comme appartenant à un mineur '
                  'est suspendu immédiatement. Vous pouvez le signaler via '
                  'la catégorie "Profil semble mineur".'
            ),
            (
              'Vos droits',
              'Vous pouvez accéder à vos données, les modifier dans '
                  '"Modifier mon profil", ou supprimer définitivement votre '
                  'compte depuis Réglages → "Supprimer mon compte". La '
                  'suppression efface profil, photos, matchs, conversations '
                  'et présence sous quelques secondes.'
            ),
            (
              'Sécurité du compte',
              'Votre mot de passe est haché côté serveur (Supabase Auth). '
                  'Les jetons d\'accès Agora sont signés à la demande, valides '
                  '15 minutes, et liés à votre identifiant pour empêcher '
                  'tout usage hors de votre date.'
            ),
            (
              'Conservation',
              'Vos données sont conservées tant que votre compte est actif. '
                  'Après suppression, elles sont effacées immédiatement, '
                  'sauf obligation légale (logs de sécurité conservés '
                  '30 jours maximum).'
            ),
            (
              'Contact',
              'Questions confidentialité : privacy@datenow.app. '
                  'Support général : support@datenow.app.'
            ),
          ]
        : const <(String, String)>[
            (
              'What we collect',
              'Your email address, profile info (first name, birth date, '
                  'gender, orientation, preferences), your photos, your '
                  'in-app preferences, and technical data (device model, OS '
                  'version, anonymised error logs) needed to operate the '
                  'service.'
            ),
            (
              'How we use it',
              'To propose relevant matches, secure your account, process '
                  'reports, improve matching quality, and send the '
                  'notifications you opted in to.'
            ),
            (
              'Camera and microphone (Agora video)',
              'During a live video date, your camera and microphone are '
                  'enabled via Agora.io, our video provider. The audio and '
                  'video stream is never recorded. The camera is blurred '
                  'for the entire date — the blur only lifts at the '
                  'post-date reveal.'
            ),
            (
              'Photos',
              'Your photos are stored privately on our Supabase server and '
                  'are only visible to another user after a mutual match '
                  '(both people opted in at the post-date reveal).'
            ),
            (
              'Hosting and providers',
              'We use Supabase for database hosting and authentication, '
                  'and Agora.io for video. None of your data is sold or '
                  'shared for advertising purposes.'
            ),
            (
              'Reporting and moderation',
              'You can report any inappropriate profile or behaviour from '
                  'the post-date screen or from a conversation. Reports are '
                  'confidential and reviewed by our team. A reported user '
                  'may be suspended without notice.'
            ),
            (
              'Protection of minors',
              'DateNow is strictly reserved for people 18 and older. Any '
                  'profile identified as belonging to a minor is suspended '
                  'immediately. You can report one via the "Profile appears '
                  'to be a minor" category.'
            ),
            (
              'Your rights',
              'You can access your data, edit it from "Edit my profile", '
                  'or permanently delete your account from Settings → '
                  '"Delete my account". Deletion wipes your profile, photos, '
                  'matches, conversations, and presence within seconds.'
            ),
            (
              'Account security',
              'Your password is hashed server-side (Supabase Auth). Agora '
                  'access tokens are signed on demand, valid for 15 minutes, '
                  'and bound to your identifier so they cannot be reused '
                  'outside your date.'
            ),
            (
              'Retention',
              'Your data is retained as long as your account is active. '
                  'After deletion it is wiped immediately, except where the '
                  'law requires otherwise (security logs kept for 30 days '
                  'maximum).'
            ),
            (
              'Contact',
              'Privacy questions: privacy@datenow.app. '
                  'General support: support@datenow.app.'
            ),
          ];

    return LegalDocumentScreen(
      title: l10n.privacyPolicyTitle,
      lastUpdated: isFr ? '24 mai 2026' : 'May 24, 2026',
      sections: sections,
    );
  }
}
