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
            majAnyDesk(); majChrome(); majPdf(); majBoutonsTout(); majGlpi();
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
        synchroniserGlpi();
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
    // Agent GLPI
    // -------------------------
    // La lecture de GLPI est automatique, l'ecriture dans le parc est un geste
    // explicite : creer une entite par effet de bord d'une generation de ZIP
    // serait une erreur qu'on ne rattrape pas.
    var caseGlpi = document.getElementById('caseGlpi');
    var blocGlpi = document.getElementById('blocGlpi');
    var glpiNomClient = document.getElementById('glpiNomClient');
    var glpiCode = document.getElementById('glpiCode');
    var glpiSousEntite = document.getElementById('glpiSousEntite');
    var glpiNouvelle = document.getElementById('glpiNouvelleSousEntite');
    var blocGlpiNouvelle = document.getElementById('blocGlpiNouvelle');
    var glpiTag = document.getElementById('glpiTag');
    var glpiTagOrigine = document.getElementById('glpiTagOrigine');
    var glpiEtat = document.getElementById('glpiEtat');
    var boutonVerifier = document.getElementById('glpiVerifier');
    var boutonCreer = document.getElementById('glpiCreer');

    function sousEntiteChoisie() {
        if (glpiSousEntite.value === '__nouvelle__') return glpiNouvelle.value.trim();
        return glpiSousEntite.value;
    }

    function etatGlpi(texte, type) {
        glpiEtat.hidden = !texte;
        glpiEtat.textContent = texte || '';
        glpiEtat.className = 'poste-glpi-etat' + (type ? ' poste-glpi-etat--' + type : '');
    }

    var glpiNomModifie = false;
    var glpiCodeModifie = false;

    // La section 1 alimente la section 4 en continu, tant que le technicien n'a
    // pas saisi autre chose ici : preparer un client de bout en bout ne doit pas
    // obliger a retaper ce qui est deja en haut de page. Des qu'un de ces deux
    // champs est touche a la main, il cesse de suivre -- meme principe que le
    // nom du poste et le mot de passe AnyDesk.
    function synchroniserGlpi() {
        if (!caseGlpi) return;
        if (!glpiNomModifie) glpiNomClient.value = champClient.value.trim();
        if (!glpiCodeModifie) glpiCode.value = champCode.value.trim();
    }

    function majGlpi() {
        if (!caseGlpi) return;
        blocGlpi.hidden = !caseGlpi.checked;
        if (caseGlpi.checked) synchroniserGlpi();
    }

    function tagPropose() {
        return glpiNomClient.value.trim() + sousEntiteChoisie();
    }

    if (caseGlpi) {
        caseGlpi.addEventListener('change', majGlpi);

        glpiNomClient.addEventListener('input', function () { glpiNomModifie = true; });
        glpiCode.addEventListener('input', function () { glpiCodeModifie = true; });
        champClient.addEventListener('input', synchroniserGlpi);

        glpiSousEntite.addEventListener('change', function () {
            blocGlpiNouvelle.hidden = glpiSousEntite.value !== '__nouvelle__';
            var option = glpiSousEntite.options[glpiSousEntite.selectedIndex];
            var tag = option ? option.dataset.tag : '';
            // Le TAG deja enregistre dans GLPI fait autorite sur la proposition.
            if (tag) {
                glpiTag.value = tag;
                glpiTagOrigine.textContent = 'Lu dans GLPI sur cette sous-entité.';
            } else {
                glpiTag.value = tagPropose();
                glpiTagOrigine.textContent = 'Proposé. Il ne vaudra que si vous créez le client dans GLPI.';
            }
        });

        glpiNouvelle.addEventListener('input', function () {
            glpiTag.value = tagPropose();
        });
    }

    var glpiEntitePrevue = '';

    function afficherPostesARanger(postes) {
        var bloc = document.getElementById('glpiPostes');
        var liste = document.getElementById('glpiPostesListe');
        liste.innerHTML = '';
        bloc.hidden = !postes || postes.length === 0;
        if (bloc.hidden) return;

        postes.forEach(function (p) {
            var li = document.createElement('li');
            var a = document.createElement('a');
            a.href = p.lien;
            a.target = '_blank';
            a.rel = 'noopener noreferrer';
            a.textContent = p.nom;
            var suite = document.createElement('em');
            suite.textContent = ' — actuellement dans ' + p.entiteActuelle;
            li.appendChild(a);
            li.appendChild(suite);
            liste.appendChild(li);
        });
    }

    function lancerVerification() {
        etatGlpi('Interrogation de GLPI…', '');
        appelGlpi('/poste/glpi/verifier', {
            code: glpiCode.value.trim(),
            nomClient: glpiNomClient.value.trim(),
            sousEntite: sousEntiteChoisie()
        }).then(appliquerReponseGlpi)
          .catch(function (e) { etatGlpi(e.message, 'erreur'); });
    }

    function afficherSuggestions(suggestions) {
        var bloc = document.getElementById('glpiSuggestions');
        var liste = document.getElementById('glpiSuggestionsListe');
        liste.innerHTML = '';
        bloc.hidden = !suggestions || suggestions.length === 0;
        if (bloc.hidden) return;

        suggestions.forEach(function (s) {
            var li = document.createElement('li');
            var bouton = document.createElement('button');
            bouton.type = 'button';
            bouton.className = 'poste-glpi-suggestion';
            bouton.textContent = s.nomComplet || s.nom;
            // Reprendre la graphie de GLPI, pas celle qui a ete tapee : c'est
            // elle qui doit servir a la suite, sinon le TAG et l'entite
            // retenus ne seraient pas ceux du parc.
            bouton.addEventListener('click', function () {
                glpiNomClient.value = s.nomClient || s.nom || '';
                glpiCode.value = s.code || '';
                glpiNomModifie = true;
                glpiCodeModifie = true;
                lancerVerification();
            });
            li.appendChild(bouton);
            liste.appendChild(li);
        });
    }

    function appliquerReponseGlpi(r) {
        afficherPostesARanger(r.postesARanger);
        afficherSuggestions(r.suggestions);
        // Creer reste ferme tant que le serveur n'a pas confirme que les deux
        // valeurs necessaires sont la : une recherche par nom seul ne doit pas
        // ouvrir une ecriture dans le parc.
        boutonCreer.hidden = !!r.trouve || r.creationPossible === false;
        if (r.trouve) glpiEntitePrevue = '';

        // La liste des sous-entites vient de GLPI ; chacune porte son TAG.
        glpiSousEntite.innerHTML = '';
        var noms = (r.sousEntites || []).map(function (e) { return e.nom; });
        if (noms.indexOf('Ordinateurs') === -1) noms.unshift('Ordinateurs');
        noms.forEach(function (nom) {
            var o = document.createElement('option');
            o.value = nom;
            o.textContent = nom;
            var trouvee = (r.sousEntites || []).filter(function (e) { return e.nom === nom; })[0];
            if (trouvee && trouvee.tag) {
                o.dataset.tag = trouvee.tag;
                o.textContent = nom + ' — TAG ' + trouvee.tag;
            }
            glpiSousEntite.appendChild(o);
        });
        var oNouvelle = document.createElement('option');
        oNouvelle.value = '__nouvelle__';
        oNouvelle.textContent = 'Nouvelle sous-entité…';
        glpiSousEntite.appendChild(oNouvelle);
        glpiSousEntite.value = 'Ordinateurs';
        blocGlpiNouvelle.hidden = true;

        glpiTag.value = r.tagPropose || '';
        glpiTagOrigine.textContent = r.tagLuDansGlpi
            ? 'Lu dans GLPI sur cette sous-entité.'
            : 'Proposé. Il ne vaudra que si vous créez le client dans GLPI.';

        if (r.trouve) {
            // La graphie de GLPI fait autorité : un 51688 saisi pour un client
            // enregistré « TSEIN - 051688 » devient 051688 dans le formulaire.
            // Sans cette reprise, la génération repartirait du code tapé.
            if (r.entite && r.entite.nomClient) {
                glpiNomClient.value = r.entite.nomClient;
                glpiNomModifie = true;
            }
            if (r.entite && r.entite.code) {
                glpiCode.value = r.entite.code;
                glpiCodeModifie = true;
            }
            etatGlpi('Client trouvé : ' + (r.entite ? r.entite.nomComplet : ''), 'ok');
        } else if (r.suggestions && r.suggestions.length) {
            glpiEntitePrevue = r.nomEntitePrevu || '';
            etatGlpi('Aucune correspondance exacte. Choisissez un client ci-dessous, '
                     + 'ou précisez votre saisie.', 'absent');
        } else if (r.creationPossible === false) {
            glpiEntitePrevue = '';
            etatGlpi('Aucun client ne correspond. Pour en créer un, renseignez le nom '
                     + 'et un code de 4 à 6 chiffres.', 'absent');
        } else {
            glpiEntitePrevue = r.nomEntitePrevu || '';
            etatGlpi('Client absent de GLPI. Il sera créé sous le nom « '
                     + (r.nomEntitePrevu || '?') + ' » — à la génération du ZIP, '
                     + 'ou tout de suite avec « Créer dans GLPI ».', 'absent');
        }
    }

    function appelGlpi(chemin, corps) {
        return fetch(chemin, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(corps)
        }).then(function (reponse) {
            return reponse.json().then(function (donnees) {
                if (!reponse.ok) {
                    throw new Error(donnees.error || 'GLPI a répondu ' + reponse.status);
                }
                return donnees;
            });
        });
    }

    if (boutonVerifier) {
        boutonVerifier.addEventListener('click', lancerVerification);

        boutonCreer.addEventListener('click', function () {
            etatGlpi('Création dans GLPI…', '');
            appelGlpi('/poste/glpi/creer', {
                code: glpiCode.value.trim(),
                nomClient: glpiNomClient.value.trim(),
                sousEntite: sousEntiteChoisie(),
                tag: glpiTag.value.trim()
            }).then(function (r) {
                appliquerReponseGlpi(r);
                etatGlpi('Entité créée dans GLPI et TAG enregistré.', 'ok');
            }).catch(function (e) { etatGlpi(e.message, 'erreur'); });
        });
    }

    // -------------------------
    // Export / import des reglages
    // -------------------------
    function lireReglages() {
        var apps = Array.prototype.filter.call(
            document.querySelectorAll('input[name="app"]'), function (c) { return c.checked; }
        ).map(function (c) { return c.value; });

        var windows = {};
        ['extensionsVisibles', 'paveNumerique', 'supprimerPubs',
         'desactiverDemarrageRapide', 'supprimerRaccourcisEdge',
         'desinstallerCcleaner'].forEach(function (nom) {
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

        if (caseGlpi && caseGlpi.checked && !glpiTag.value.trim()) {
            afficher("L'agent GLPI est coché mais aucun TAG n'est résolu : "
                     + 'utilisez le bouton « Vérifier dans GLPI ».', true);
            glpiTag.focus();
            return;
        }

        if (caseGlpi && caseGlpi.checked) {
            document.getElementById('glpiSousEntiteRetenue').value = sousEntiteChoisie();

            // L'equivalent du « Confirmez-vous la creation de l'entite ? » de
            // l'outil interne : rien ne s'ecrit dans le parc sans que le nom
            // exact ait ete lu et valide.
            if (glpiEntitePrevue && !confirm(
                    'Le client est absent de GLPI.\n\n'
                    + 'L\'entité « ' + glpiEntitePrevue
                    + ' » et sa sous-entité « ' + sousEntiteChoisie()
                    + ' » vont être créées dans le parc.\n\n'
                    + 'Continuer ?')) {
                afficher('Génération annulée : rien n\'a été créé dans GLPI.', false);
                return;
            }
        }

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
    // Aucun compte propose d'office : la liste part vide et le technicien
    // ajoute ce dont il a besoin. Beaucoup d'interventions n'en creent aucun.
    majNomPoste();
    majAnyDesk();
    majChrome();
    majPdf();
    majBoutonsTout();
    majGlpi();
})();
