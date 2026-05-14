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
              'Vos informations de profil (prénom, âge, genre, orientation, '
                  'préférences), vos photos, vos préférences d\'application, '
                  'l\'usage et les données techniques nécessaires au bon '
                  'fonctionnement du service.'
            ),
            (
              'Pourquoi nous les utilisons',
              'Pour vous proposer des matchs pertinents, sécuriser votre '
                  'compte, améliorer la qualité du matching, et vous envoyer '
                  'les notifications que vous avez activées.'
            ),
            (
              'Avec qui nous partageons',
              'Avec personne pour de la vente. Avec nos prestataires '
                  'techniques (hébergement, paiement, analytics anonymisé) '
                  'strictement pour faire fonctionner l\'application.'
            ),
            (
              'Vos droits',
              'Vous pouvez accéder, modifier, exporter ou supprimer vos '
                  'données depuis l\'écran "Modifier mon profil" et l\'action '
                  '"Supprimer mon compte". Une demande prend effet sous 30 jours.'
            ),
            (
              'Photos',
              'Vos photos sont stockées de façon privée et ne sont jamais '
                  'visibles avant la fin d\'un date en direct de 5 minutes.'
            ),
            (
              'Contact',
              'Pour toute question : privacy@datenow.app.'
            ),
          ]
        : const <(String, String)>[
            (
              'What we collect',
              'Your profile info (first name, age, gender, orientation, '
                  'preferences), your photos, your in-app preferences, plus '
                  'usage and technical data needed to operate the service.'
            ),
            (
              'How we use it',
              'To propose relevant matches, secure your account, improve '
                  'matching quality, and send the notifications you opted in to.'
            ),
            (
              'Who we share it with',
              'We never sell your data. We share strictly with our technical '
                  'providers (hosting, payments, anonymised analytics) to keep '
                  'the app running.'
            ),
            (
              'Your rights',
              'You can access, edit, export, or delete your data from the '
                  '"Edit my profile" screen and the "Delete my account" action. '
                  'Requests are honoured within 30 days.'
            ),
            (
              'Photos',
              'Your photos are stored privately and are never visible until '
                  'a successful 5-minute live date completes.'
            ),
            (
              'Contact',
              'Questions? privacy@datenow.app.'
            ),
          ];

    return LegalDocumentScreen(
      title: l10n.privacyPolicyTitle,
      lastUpdated: isFr ? '13 mai 2026' : 'May 13, 2026',
      sections: sections,
    );
  }
}
