# DateNow — site public

Site statique (HTML/CSS only). **Aucun JavaScript, aucun tracking, aucun cookie, aucun backend.**
Indépendant de l’application Flutter (rien d’autre que ce dossier `website/`).

## Pages
| URL publique | Fichier |
|---|---|
| `/` | `index.html` |
| `/privacy` | `privacy.html` |
| `/terms` | `terms.html` |
| `/support` | `support.html` |
| `/delete-account` | `delete-account.html` |

Les URLs « propres » (sans `.html`) sont gérées par l’hébergeur (Cloudflare Pages et Vercel le font nativement ; `vercel.json` active `cleanUrls`).

Autres fichiers : `styles.css`, `favicon.svg`, `robots.txt`, `sitemap.xml`, `404.html`, `vercel.json`.

## Lancer en local
Depuis le dossier `website/` :

```bash
# Option 1 — Python (préinstallé sur macOS)
cd website
python3 -m http.server 8000
# → http://localhost:8000
```

```bash
# Option 2 — Node
npx serve website
```

Ouvrez ensuite http://localhost:8000 (ou l’URL affichée). En local, accédez aux pages via `privacy.html`, `terms.html`, etc. (les URLs propres `/privacy` sont activées par l’hébergeur en prod).

## Déployer

### Cloudflare Pages
1. Poussez ce dépôt sur GitHub (ou utilisez `wrangler`).
2. Cloudflare Dashboard → **Workers & Pages** → **Create** → **Pages** → **Connect to Git**.
3. Build settings :
   - **Build command** : *(vide)*
   - **Build output directory** : `website`
4. Déployez, puis **Custom domains** → ajoutez `getdatenow.app` (Cloudflare gère DNS + HTTPS).

CLI alternative :
```bash
npm i -g wrangler
wrangler pages deploy website --project-name datenow-site
```

### Vercel
1. Vercel → **Add New** → **Project** → importez le dépôt.
2. **Root Directory** : `website` · **Framework Preset** : *Other* · build command vide.
3. Déployez, puis **Settings → Domains** → ajoutez `getdatenow.app`.

CLI alternative :
```bash
npm i -g vercel
cd website
vercel --prod
```

## Domaine
Pointez `getdatenow.app` vers Cloudflare Pages ou Vercel selon l’hébergeur choisi.
Mettez ces URLs dans **App Store Connect** (Privacy Policy URL, Support URL) et **Google Play Console** (politique de confidentialité + URL de suppression de compte) :
- Confidentialité : `https://getdatenow.app/privacy`
- Support : `https://getdatenow.app/support`
- Suppression de compte : `https://getdatenow.app/delete-account`
