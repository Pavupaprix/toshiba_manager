/* Carte « Partage Scan vers dossier » de la page /installer
 *
 * Le mot de passe du compte de depot des scans n'est plus ecrit dans le depot :
 * il est saisi ici et injecte dans le .bat a la generation. Il part en POST et
 * jamais en parametre d'URL, ou il finirait dans les journaux du proxy et dans
 * l'historique du navigateur.
 */
(function () {
    'use strict';

    var GABARIT = 'OmbI@';

    var champCode = document.getElementById('partageCode');
    var champMotDePasse = document.getElementById('partageMotDePasse');
    var bouton = document.getElementById('partageTelecharger');
    var etat = document.getElementById('partageEtat');

    if (!bouton) return;

    function afficher(texte, type) {
        etat.hidden = !texte;
        etat.textContent = texte || '';
        etat.className = 'poste-glpi-etat' + (type ? ' poste-glpi-etat--' + type : '');
    }

    // Le champ suit le code client tant que le technicien n'y a pas touche.
    var modifie = false;
    champMotDePasse.addEventListener('input', function () { modifie = true; });

    champCode.addEventListener('input', function () {
        if (modifie) return;
        var code = champCode.value.trim();
        champMotDePasse.value = code ? GABARIT + code : '';
    });

    bouton.addEventListener('click', function () {
        var motDePasse = champMotDePasse.value.trim();
        if (!motDePasse) {
            afficher('Renseignez le code client, ou saisissez directement le mot de passe.', 'erreur');
            champMotDePasse.focus();
            return;
        }

        afficher('Génération en cours…', '');
        var donnees = new FormData();
        donnees.append('motDePasse', motDePasse);

        fetch('/download-bat', { method: 'POST', body: donnees })
            .then(function (reponse) {
                if (!reponse.ok) {
                    return reponse.json().then(function (d) {
                        throw new Error(d.error || 'Le serveur a répondu ' + reponse.status);
                    });
                }
                return reponse.blob().then(function (blob) {
                    var lien = document.createElement('a');
                    lien.href = URL.createObjectURL(blob);
                    lien.download = 'Toshiba+Partage.bat';
                    lien.click();
                    URL.revokeObjectURL(lien.href);
                    afficher('Script généré. Saisissez le même mot de passe dans le copieur.', 'ok');
                });
            })
            .catch(function (e) { afficher(e.message, 'erreur'); });
    });
})();
