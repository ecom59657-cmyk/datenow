# Fiche App Store — texte prêt à coller

> Couvre les points 7.2, 7.3 et 7.4 de la checklist de
> `APPLE_4_3B_APPEAL.md`. Tout est mesuré contre les limites d'App Store
> Connect ; le compteur est indiqué à chaque champ.
>
> Le principe qui gouverne tout ce document : **un rejet 4.3(b) se joue à
> moitié sur la fiche**. Un reviewer qui lit « Rencontre, chat, célibataires »
> a déjà rangé l'app dans le peloton avant d'ouvrir le binaire. Chaque champ
> doit donc dire la même chose que l'app fait vraiment, et le dire vite.

## 1. Sous-titre — 30 caractères

**Retenu : `Le date vidéo avant la photo`** (28)

Il dit la mécanique, pas la catégorie, et il est vérifiable à l'écran en
quatre-vingt-dix secondes. C'est ce qui compte pour un 4.3(b).

| Candidat | Car. | Verdict |
|---|---|---|
| Le date vidéo avant la photo | 28 | **retenu** |
| Parlez d'abord, voyez ensuite | 29 | bon second, écho au site |
| 5 min en vidéo floutée | 22 | trop cryptique seul |
| Rencontre en live, pas en swipe | 31 | **dépasse la limite** |
| La voix d'abord, le visage après | 32 | **dépasse la limite** |

> Les deux dernières sont les formulations proposées par le dossier d'appel
> §7.2 : elles ne tiennent pas dans le champ. Corrigé ici.

## 2. Mots-clés — 100 caractères, séparés par des virgules sans espace

**Retenu (87) :**

```
vidéo,direct,flouté,appel vidéo,5 minutes,conversation,voix,sans swipe,rencontrer,amour
```

Il y a une tension réelle à assumer : dégénériser sert l'argument 4.3(b) mais
coûte en découvrabilité, parce que « rencontre » est ce que les gens tapent.
L'arbitrage retenu garde deux portes d'entrée génériques (`rencontrer`,
`amour`) et supprime celles qui **évoquent précisément le schéma Tinder** —
`swipe` seul, `match`, `célibataires`. On reste trouvable sans se ranger
soi-même dans la catégorie qu'Apple nous reproche.

Inutile de répéter le nom de l'app et les mots du sous-titre : Apple les
indexe déjà.

## 3. Description — la première ligne fait le travail

Les trois premières lignes sont seules visibles avant « plus ». Elles portent
la phrase-pivot du dossier, en français :

```
Sur DateNow, vous rencontrez quelqu'un lors d'un date vidéo de 5 minutes,
caméra floutée, avant d'avoir vu sa photo ou échangé un message.

Pas de catalogue de profils. Pas de swipe. On vous présente une personne
disponible maintenant, et vous vous parlez pour de vrai.

Comment ça marche
• Vous êtes disponible, quelqu'un d'autre l'est aussi : on vous met en
  relation en temps réel.
• Votre premier contact est un date vidéo de 5 minutes. La caméra reste
  floutée du début à la fin.
• À la fin seulement, si vous êtes tous les deux d'accord, les visages se
  révèlent — et la conversation s'ouvre.

Ce que DateNow ne fait pas
• Aucune pile de profils à balayer.
• Aucune photo avant l'appel.
• Aucune conversation écrite avant de s'être parlé.

Identités vérifiées, modération des photos, 18 ans et plus.
```

## 4. Cohérence avec le site

`getdatenow.app` porte déjà « Parlez d'abord. Le visage viendra ensuite. » et
« des dates vidéo floutés avant reveal ». Le message est le même — Apple peut
consulter le site, et une divergence entre la fiche et la page publique est
exactement ce qui fait douter un reviewer.

## 5. Ce qui reste à produire

Le texte ne suffit pas : les captures et l'App Preview pèsent plus lourd que
lui dans un 4.3(b). Voir le storyboard en §5 du dossier d'appel, et
`REDESIGN_TWO_PHONE_CHECK.md` pour le fait que trois de ces captures ne
peuvent être prises que pendant le test à deux téléphones.
