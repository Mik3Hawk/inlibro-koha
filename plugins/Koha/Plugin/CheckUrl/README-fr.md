
# Koha Plugin – CheckUrl

## Description

L’extension **CheckUrl** pour le SIGB **Koha** permet d’executer le script interne
**`check-url-quick.pl`** directement depuis l’interface de Koha.
Elle simplifie la verification des liens (notamment ceux en zone **856u**) dans les notices bibliographiques.

---

## Fonctionnalités

* Execution du script **`check-url-quick.pl`** depuis Koha.
* Page d’accueil avec un bouton **« Vérifier URL »**.
* Page de resultats affichant un rapport des URL et des codes de retour.

---

## Installation

1. Se connecter à l’intranet de Koha. Puis, aller dans Administrations > Gerer les extensions

2. Cliquer sur le bouton "Televerser une extension"

2. Redemarrer votre Base de Donnees si necessaire.

3. Activer le plugin via le menu :
   **Administration > Extensions Koha > plugin CheckUrl > Action : Activer**

**Prérequis** : 
 * le script `check-url-quick.pl` doit etre present dans `misc/cronjobs/`.
 * Vous devez avoir prealablement configure votre systeme Koha pour recevoir des extensions.

---

## Utilisation

1. Se connecter à l’intranet de Koha.
2. Executer le plugin via le menu :
   **Administration > Extensions Koha > plugin CheckUrl > Action : Exécuter**
3. La page d’accueil du plugin s’affiche avec un bouton **« Vérifier URL »**.
4. Cliquer sur le bouton pour lancer l’analyse.
5. Les resultats apparaissent sous forme de tableau.

---

## Exemple de résultats

```
Check URL Results

83    /ftp://ftp.umontreal.ca/               599 Seuls les protocoles http et https sont acceptés
247   https://en.wikipedia.org/wiki/Z123456  404 Fichier introuvable
345   /irc.oftc.net:6667                     599 Seuls les protocoles http et https sont acceptés
556   /file://home/marieluce/Downloads/...   599 Seuls les protocoles http et https sont acceptés
686   http://www.gutenberg.org/ebooks/1691   404 Fichier introuvable
2688  http://www.gutenberg.org/ebooks/23651  599 Seuls les protocoles http et https sont acceptés
```

* La premiere colonne correspond au **numéro de notice**.
* La deuxieme colonne est l’URL testee.
* La troisieme colonne est le code de retour ou le message d’erreur.

---

## Maintenance

* **Désinstallation** : possible depuis l’interface (aucune donnée persistante).
* **Mises à jour** : desinstaller l’ancienne version avant d’installer la nouvelle.

---

## Métadonnées

* **Nom** : CheckUrl
* **Auteurs** : Alexandre Noël, Noah Tremblay
* **Description** : Execute `check-url-quick.pl` et affiche les resultats dans Koha
* **Version** : 2.0
* **Date de création** : 15 aout 2024
* **Dernière mise à jour** : 8 septembre 2025

---

