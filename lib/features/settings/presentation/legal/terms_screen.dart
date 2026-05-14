import 'package:flutter/widgets.dart';

import '../../../../l10n/app_localizations.dart';
import 'legal_document_screen.dart';

/// Static placeholder content for the Terms of Use. Real copy lives with
/// legal — this MVP build ships generic but plausible text so the screen
/// is exploitable end-to-end.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isFr = Localizations.localeOf(context).languageCode == 'fr';

    final sections = isFr
        ? const <(String, String)>[
            (
              '1. Acceptation',
              'En utilisant DateNow, vous acceptez les présentes conditions. '
                  'Si vous n\'êtes pas d\'accord, n\'utilisez pas l\'application.'
            ),
            (
              '2. Comment ça fonctionne',
              'DateNow propose des dates audio ou vidéo en direct de 5 minutes '
                  'entre membres compatibles et en ligne. À la fin de chaque date, '
                  'chacun choisit de continuer, d\'échanger les profils ou de passer.'
            ),
            (
              '3. Compte et éligibilité',
              'Vous devez avoir 18 ans ou plus pour utiliser DateNow. Vous êtes '
                  'responsable de la confidentialité de vos identifiants.'
            ),
            (
              '4. Comportement attendu',
              'Soyez respectueux. Les insultes, le harcèlement, le contenu '
                  'illégal et l\'usurpation d\'identité sont interdits et peuvent '
                  'entraîner la suspension de votre compte.'
            ),
            (
              '5. Photos et confidentialité',
              'Les photos sont privées tant qu\'un date en direct de 5 minutes '
                  'n\'a pas été terminé avec succès. Les autres membres ne voient '
                  'qu\'une silhouette avant cette étape.'
            ),
            (
              '6. Modifications',
              'Nous pouvons mettre à jour ces conditions ; vous serez informé '
                  'dans l\'application avant qu\'elles ne prennent effet.'
            ),
          ]
        : const <(String, String)>[
            (
              '1. Acceptance',
              'By using DateNow, you agree to these terms. If you do not '
                  'agree, please do not use the app.'
            ),
            (
              '2. How it works',
              'DateNow proposes 5-minute live audio or video dates between '
                  'compatible, online members. At the end of each date, both '
                  'people choose to continue, swap profiles, or move on.'
            ),
            (
              '3. Account and eligibility',
              'You must be 18 or older to use DateNow. You are responsible '
                  'for keeping your credentials confidential.'
            ),
            (
              '4. Expected behaviour',
              'Be respectful. Insults, harassment, illegal content and '
                  'impersonation are prohibited and may result in your '
                  'account being suspended.'
            ),
            (
              '5. Photos and privacy',
              'Photos are private until a successful 5-minute live date has '
                  'completed. Other members only see a silhouette until then.'
            ),
            (
              '6. Changes',
              'We may update these terms; you will be notified in-app before '
                  'any change takes effect.'
            ),
          ];

    return LegalDocumentScreen(
      title: l10n.termsTitle,
      lastUpdated: isFr ? '13 mai 2026' : 'May 13, 2026',
      sections: sections,
    );
  }
}
