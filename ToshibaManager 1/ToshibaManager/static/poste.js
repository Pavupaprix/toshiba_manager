/* Page « Installer un poste » — /poste
 *
 * Trois responsabilites, sans dependance externe :
 *   - proposer le nom du poste et le tenir dans les 15 caracteres de Windows ;
 *   - gerer la liste de comptes locaux, qui n'est pas exprimable en champs de
 *     formulaire classiques (les cases decochees ne se postent pas) : elle est
 *     serialisee en JSON dans un champ cache au moment de l'envoi ;
 *   - exporter/importer les reglages, entierement dans le navigateur — les mots
 *     de passe ne repassent jamais par le serveur.
 */
(function () {
    'use strict';

    var GABARIT_MOT_DE_PASSE = 'OmbI@';
    var MAX_NOM_POSTE = 15;

    var form = document.getElementById('formPoste');
    var champClient = document.getElementById('client');
    var champTrigramme = document.getElementById('trigramme');
    var champCode = document.getElementById('codeClient');
    var caseRenommer = document.getElementById('renommerPoste');
    var champNomPoste = document.getElementById('nomPoste');
    var champNumero = document.getElementById('numeroPoste');
    var compteur = document.getElementById('nomPosteCompteur');
    var champAnyDesk = document.getElementById('anydeskMotDePasse');
    var blocAnyDesk = document.getElementById('blocAnyDesk');
    var blocChrome = document.getElementById('blocChrome');
    var avertPdf = document.getElementById('avertPdf');
    var avertUac = document.getElementById('avertUac');
    var champUac = document.getElementById('uac');
    var listeComptes = document.getElementById('listeComptes');
    var message = document.getElementById('messagePoste');
    var champComptes = document.getElementById('comptesJson');

    function caseApp(id) {
        return document.querySelector('input[data-app="' + id + '"]');
    }

    function motDePasseDerive() {
        var code = champCode.value.trim();
        return code ? GABARIT_MOT_DE_PASSE + code : '';
    }

    function afficher(texte, erreur) {
        message.hidden = !texte;
        message.textContent = texte || '';
        message.classList.toggle('error', !!erreur);
        if (texte) message.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }

    // -------------------------
    // Nom du poste
    // -------------------------
    // Le nom propose est AA-MM-TRIGRAMME-NN. Windows plafonne a 15 caracteres :
    // c'est le trigramme qui est rogne, jamais la date ni le numero, pour que
    // deux postes du meme client restent distinguables.
    function nomPropose() {
        var trigramme = champTrigramme.value.toUpperCase().replace(/[^A-Z0-9]/g, '');
        var numero = ('0' + (parseInt(champNumero.value, 10) || 1)).slice(-2);
        var prefixe = window.POSTE_ANNEE_MOIS + '-';
        var suffixe = '-' + numero;
        var place = MAX_NOM_POSTE - prefixe.length - suffixe.length;
        return prefixe + trigramme.slice(0, Math.max(place, 0)) + suffixe;
    }

    var nomPosteModifie = false;

    function majNomPoste() {
        if (!nomPosteModifie) champNomPoste.value = nomPropose();
        compteur.textContent = String(champNomPoste.value.length);
    }

    champNomPoste.addEventListener('input', function () {
        nomPosteModifie = true;
        compteur.textContent = String(champNomPoste.value.length);
    });

    caseRenommer.addEventListener('change', function () {
        champNomPoste.disabled = !caseRenommer.checked;
        champNumero.disabled = !caseRenommer.checked;
        champNomPoste.required = caseRenommer.checked;
        majNomPoste();
    });

    champTrigramme.addEventListener('input', majNomPoste);
    champNumero.addEventListener('input', majNomPoste);

    // -------------------------
    // Options revelees par une case
    // -------------------------
    var anydeskModifie = false;
    if (champAnyDesk) {
        champAnyDesk.addEventListener('input', function () { anydeskModifie = true; });
    }

    function majAnyDesk() {
        var coche = caseApp('anydesk') && caseApp('anydesk').checked;
        blocAnyDesk.hidden = !coche;
        if (!anydeskModifie) champAnyDesk.value = motDePasseDerive();
        champAnyDesk.required = coche;
    }

    function majChrome() {
        var coche = caseApp('chrome') && caseApp('chrome').checked;
        blocChrome.hidden = !coche;
    }

    function majPdf() {
        var acrobat = caseApp('acrobat'), foxit = caseApp('foxit');
        avertPdf.hidden = !(acrobat && foxit && acrobat.checked && foxit.checked);
    }

    champUac.addEventListener('change', function () {
        avertUac.hidden = champUac.value !== 'desactive';
    });

    Array.prototype.forEach.call(document.querySelectorAll('input[name="app"]'), function (c) {
        c.addEventListener('change', function () {
            majAnyDesk(); majChrome(); majPdf(); majBoutonsTout();
        });
    });

    // -------------------------
    // Tout cocher / tout decocher, par categorie
    // -------------------------
    // Un seul bouton qui bascule, plutot que deux : son libelle dit toujours ce
    // qu'un clic va faire. Les entrees grisees (installeur absent du serveur)
    // sont ignorees -- les cocher ne produirait qu'un refus a la generation.
    function casesDe(bouton) {
        return Array.prototype.slice.call(
            bouton.closest('section').querySelectorAll('input[name="app"]:not([disabled])'));
    }

    function majBoutonsTout() {
        Array.prototype.forEach.call(document.querySelectorAll('[data-tout]'), function (b) {
            var cases = casesDe(b);
            var toutes = cases.length > 0 && cases.every(function (c) { return c.checked; });
            b.textContent = toutes ? 'Tout décocher' : 'Tout cocher';
            b.disabled = cases.length === 0;
        });
    }

    Array.prototype.forEach.call(document.querySelectorAll('[data-tout]'), function (b) {
        b.addEventListener('click', function () {
            var cases = casesDe(b);
            var cocher = !cases.every(function (c) { return c.checked; });
            cases.forEach(function (c) {
                if (c.checked === cocher) return;
                c.checked = cocher;
                // Une affectation n'emet pas 'change' : sans ce declenchement,
                // le champ AnyDesk et l'option Chrome ne suivraient pas.
                c.dispatchEvent(new Event('change', { bubbles: true }));
            });
            majBoutonsTout();
        });
    });

    champCode.addEventListener('input', function () {
        majAnyDesk();
        majMotsDePasseDerives();
    });

    // -------------------------
    // Comptes locaux
    // -------------------------
    // Chaque ligne porte un drapeau « derive » : tant que le technicien n'a pas
    // touche au mot de passe, il suit le code client. Des qu'il le saisit a la
    // main, la ligne cesse de bouger toute seule.
    function ajouterCompte(valeurs) {
        valeurs = valeurs || {};
        var ligne = document.createElement('div');
        ligne.className = 'poste-compte';
        ligne.innerHTML =
            '<div class="poste-compte-champs">' +
            '  <label>Nom<input type="text" class="c-nom" maxlength="20" pattern="^[A-Za-z0-9._-]{1,20}$" placeholder="utilisateur"></label>' +
            '  <label>Mot de passe<input type="text" class="c-mdp" autocomplete="off" placeholder="vide = sans mot de passe"></label>' +
            '  <label>Droits<select class="c-role"><option value="standard">Utilisateur standard</option><option value="admin">Administrateur</option></select></label>' +
            '  <button type="button" class="btn btn-secondary c-suppr" title="Supprimer ce compte">✕</button>' +
            '</div>' +
            '<div class="poste-compte-options">' +
            '  <label class="poste-case"><input type="checkbox" class="c-expire" checked><span>Mot de passe qui n\'expire jamais</span></label>' +
            '  <label class="poste-case"><input type="checkbox" class="c-auto"><span>Connexion automatique</span></label>' +
            '</div>';

        ligne.querySelector('.c-nom').value = valeurs.nom || '';
        ligne.querySelector('.c-mdp').value = valeurs.motDePasse || '';
        ligne.querySelector('.c-role').value = valeurs.admin ? 'admin' : 'standard';
        ligne.querySelector('.c-expire').checked = valeurs.motDePasseNExpireJamais !== false;
        ligne.querySelector('.c-auto').checked = !!valeurs.autologon;
        ligne.dataset.derive = valeurs.derive ? '1' : '';

        ligne.querySelector('.c-mdp').addEventListener('input', function () {
            ligne.dataset.derive = '';
        });
        ligne.querySelector('.c-suppr').addEventListener('click', function () {
            ligne.remove();
        });
        // Windows n'accepte qu'une seule ouverture de session automatique.
        ligne.querySelector('.c-auto').addEventListener('change', function () {
            if (!this.checked) return;
            Array.prototype.forEach.call(listeComptes.querySelectorAll('.c-auto'), function (c) {
                if (c !== this) c.checked = false;
            }, this);
        });

        listeComptes.appendChild(ligne);
        return ligne;
    }

    function majMotsDePasseDerives() {
        Array.prototype.forEach.call(listeComptes.querySelectorAll('.poste-compte'), function (l) {
            if (l.dataset.derive) l.querySelector('.c-mdp').value = motDePasseDerive();
        });
    }

    // pourEnvoi : les lignes qui suivent le code client partent avec le jeton
    // {code} plutot qu'avec le mot de passe affiche. Sans ca, un code client
    // vide produirait en silence des comptes sans mot de passe -- adminomb
    // compris -- au lieu du refus explicite attendu.
    function lireComptes(pourEnvoi) {
        return Array.prototype.map.call(
            listeComptes.querySelectorAll('.poste-compte'), function (l) {
                var derive = !!l.dataset.derive;
                return {
                    nom: l.querySelector('.c-nom').value.trim(),
                    motDePasse: (pourEnvoi && derive) ? '{code}' : l.querySelector('.c-mdp').value,
                    admin: l.querySelector('.c-role').value === 'admin',
                    motDePasseNExpireJamais: l.querySelector('.c-expire').checked,
                    autologon: l.querySelector('.c-auto').checked,
                    derive: derive
                };
            }).filter(function (c) { return c.nom !== ''; });
    }

    document.getElementById('ajouterCompte').addEventListener('click', function () {
        ajouterCompte();
    });

    // -------------------------
    // Export / import des reglages
    // -------------------------
    function lireReglages() {
        var apps = Array.prototype.filter.call(
            document.querySelectorAll('input[name="app"]'), function (c) { return c.checked; }
        ).map(function (c) { return c.value; });

        var windows = {};
        ['extensionsVisibles', 'paveNumerique', 'supprimerPubs',
         'desactiverDemarrageRapide', 'desinstallerCcleaner'].forEach(function (nom) {
            windows[nom] = document.querySelector('input[name="' + nom + '"]').checked;
        });

        return {
            client: champClient.value,
            trigramme: champTrigramme.value,
            codeClient: champCode.value,
            renommerPoste: caseRenommer.checked,
            numeroPoste: champNumero.value,
            nomPoste: nomPosteModifie ? champNomPoste.value : null,
            applications: apps,
            navigateurParDefaut: document.querySelector('input[name="navigateurParDefaut"]').checked,
            anydeskMotDePasse: anydeskModifie ? champAnyDesk.value : null,
            uac: champUac.value,
            windows: windows,
            comptes: lireComptes()
        };
    }

    function appliquerReglages(r) {
        champClient.value = r.client || '';
        champTrigramme.value = r.trigramme || '';
        champCode.value = r.codeClient || '';
        caseRenommer.checked = !!r.renommerPoste;
        champNumero.value = r.numeroPoste || 1;
        champNomPoste.disabled = !caseRenommer.checked;
        champNumero.disabled = !caseRenommer.checked;

        var apps = r.applications || [];
        Array.prototype.forEach.call(document.querySelectorAll('input[name="app"]'), function (c) {
            c.checked = !c.disabled && apps.indexOf(c.value) !== -1;
        });
        document.querySelector('input[name="navigateurParDefaut"]').checked =
            r.navigateurParDefaut !== false;

        var windows = r.windows || {};
        Object.keys(windows).forEach(function (nom) {
            var c = document.querySelector('input[name="' + nom + '"]');
            if (c) c.checked = !!windows[nom];
        });
        champUac.value = r.uac || 'inchange';
        avertUac.hidden = champUac.value !== 'desactive';

        listeComptes.innerHTML = '';
        (r.comptes || []).forEach(ajouterCompte);

        anydeskModifie = r.anydeskMotDePasse !== null && r.anydeskMotDePasse !== undefined;
        if (anydeskModifie) champAnyDesk.value = r.anydeskMotDePasse;
        nomPosteModifie = !!r.nomPoste;
        if (nomPosteModifie) champNomPoste.value = r.nomPoste;

        majNomPoste();
        majAnyDesk();
        majChrome();
        majPdf();
        majBoutonsTout();
    }

    document.getElementById('exporterReglages').addEventListener('click', function () {
        var nom = (champClient.value.trim() || 'poste').replace(/[^A-Za-z0-9 ._-]/g, '');
        var blob = new Blob([JSON.stringify(lireReglages(), null, 2)],
                            { type: 'application/json' });
        var lien = document.createElement('a');
        lien.href = URL.createObjectURL(blob);
        lien.download = 'Reglages ' + nom + '.json';
        lien.click();
        URL.revokeObjectURL(lien.href);
        afficher('Réglages exportés. Ce fichier contient les mots de passe : rangez-le avec le dossier client.', false);
    });

    var fichierReglages = document.getElementById('fichierReglages');
    document.getElementById('importerReglages').addEventListener('click', function () {
        fichierReglages.click();
    });
    fichierReglages.addEventListener('change', function () {
        var fichier = fichierReglages.files[0];
        if (!fichier) return;
        var lecteur = new FileReader();
        lecteur.onload = function () {
            try {
                appliquerReglages(JSON.parse(lecteur.result));
                afficher('Réglages importés depuis ' + fichier.name + '.', false);
            } catch (e) {
                afficher("Ce fichier n'est pas un fichier de réglages valide.", true);
            }
            fichierReglages.value = '';
        };
        lecteur.readAsText(fichier);
    });

    // -------------------------
    // Envoi
    // -------------------------
    // Envoi en fetch plutot qu'en POST classique : sur refus, le serveur renvoie
    // un message en clair qu'on affiche dans la page, au lieu de remplacer le
    // formulaire rempli par une page d'erreur.
    form.addEventListener('submit', function (e) {
        e.preventDefault();
        champComptes.value = JSON.stringify(lireComptes(true));
        afficher('Génération en cours…', false);

        var donnees = new FormData(form);
        // Meme raison que pour les comptes : tant que le technicien n'a pas
        // saisi ce mot de passe lui-meme, c'est le serveur qui le derive.
        if (!anydeskModifie) donnees.set('anydeskMotDePasse', '{code}');

        fetch(form.action, { method: 'POST', body: donnees })
            .then(function (reponse) {
                if (!reponse.ok) {
                    return reponse.text().then(function (texte) { throw new Error(texte); });
                }
                var nom = 'Installation PC.zip';
                var entete = reponse.headers.get('Content-Disposition') || '';
                var trouve = /filename="([^"]+)"/.exec(entete);
                if (trouve) nom = trouve[1];
                return reponse.blob().then(function (blob) {
                    var lien = document.createElement('a');
                    lien.href = URL.createObjectURL(blob);
                    lien.download = nom;
                    lien.click();
                    URL.revokeObjectURL(lien.href);
                    afficher('ZIP généré : ' + nom, false);
                });
            })
            .catch(function (err) {
                afficher(err.message || 'La génération a échoué.', true);
            });
    });

    // -------------------------
    // Etat initial
    // -------------------------
    // Le compte adminomb est propose d'office : c'est celui de toutes les
    // interventions OMB. Il reste supprimable.
    ajouterCompte({ nom: 'adminomb', admin: true, motDePasseNExpireJamais: true, derive: true });
    majNomPoste();
    majAnyDesk();
    majChrome();
    majPdf();
    majBoutonsTout();
})();
