#!/bin/bash
# patch_pages.sh — injecte les exemples concrets dans les pages guides
# Usage : bash patch_pages.sh depuis la racine du projet Rails

set -e
echo "🔧 Patch des pages guides Lotys..."

# ─────────────────────────────────────────────
# 1. show.html.erb — lien sans underline
# ─────────────────────────────────────────────
sed -i 's/class: "text-xs text-emerald-600 underline"/class: "text-xs text-emerald-600 font-semibold hover:text-emerald-700 transition"/' \
  app/views/properties/show.html.erb
echo "✅ show.html.erb — lien corrigé"

# ─────────────────────────────────────────────
# 2. panneaux_solaires — exemples avant Sources
# ─────────────────────────────────────────────
if grep -q "border-l-4" app/views/pages/panneaux_solaires.html.erb; then
  echo "⏭  panneaux_solaires — exemples déjà présents"
else
python3 << 'EOF'
path = "app/views/pages/panneaux_solaires.html.erb"
with open(path) as f: c = f.read()
bloc = """  <div class="bg-white border border-gray-200 rounded-2xl p-6 mb-6">
    <h2 class="text-xl font-bold text-gray-900 mb-5">💡 Trois exemples concrets</h2>
    <div class="space-y-5">
      <div class="border-l-4 border-amber-400 pl-4">
        <p class="font-bold text-gray-900 mb-1">Maison 90 m² à Laxou, toiture plein sud</p>
        <p class="text-base text-gray-600 leading-relaxed">Installation de 6 kWc en 2023. Coût total après prime : 8 200 €. Économies annuelles : 680 €. Surplus revendu : 210 €/an. Retour sur investissement estimé à 11 ans. Amélioration DPE : de D à C.</p>
      </div>
      <div class="border-l-4 border-amber-400 pl-4">
        <p class="font-bold text-gray-900 mb-1">Appartement en copropriété, rue de la République Nancy</p>
        <p class="text-base text-gray-600 leading-relaxed">Résolution AG votée en 2024 pour une installation collective de 18 kWc sur toiture-terrasse. Coût par copropriétaire : 2 400 € (10 lots). Économies sur les charges communes : −180 €/an/lot. Financement via éco-PTZ copropriété.</p>
      </div>
      <div class="border-l-4 border-amber-400 pl-4">
        <p class="font-bold text-gray-900 mb-1">Petite maison de 46 m², orientation est-ouest</p>
        <p class="text-base text-gray-600 leading-relaxed">Configuration sous-optimale mais viable : 3 kWc installés, production réduite de 20% vs plein sud. Coût : 5 800 € après prime. Économies : 280 €/an. L'installation reste rentable en 14 ans.</p>
      </div>
    </div>
  </div>

"""
anchor = '  <div class="text-xs text-gray-400 space-y-1">'
if anchor in c:
    c = c.replace(anchor, bloc + anchor)
    with open(path, "w") as f: f.write(c)
    print("✅ panneaux_solaires — exemples injectés")
else:
    print("⚠️  anchor non trouvé dans panneaux_solaires")
EOF
fi

# ─────────────────────────────────────────────
# 3. location_meublee — exemples avant Sources
# ─────────────────────────────────────────────
if grep -q "border-l-4" app/views/pages/location_meublee.html.erb; then
  echo "⏭  location_meublee — exemples déjà présents"
else
python3 << 'EOF'
path = "app/views/pages/location_meublee.html.erb"
with open(path) as f: c = f.read()
bloc = """  <div class="bg-white border border-gray-200 rounded-2xl p-6 mb-6">
    <h2 class="text-xl font-bold text-gray-900 mb-5">💡 Trois exemples concrets</h2>
    <div class="space-y-5">
      <div class="border-l-4 border-emerald-400 pl-4">
        <p class="font-bold text-gray-900 mb-1">Studio 25 m², quartier Université Nancy, bail étudiant</p>
        <p class="text-base text-gray-600 leading-relaxed">Loyer nu équivalent : 380 €/mois. En meublé avec bail 9 mois étudiant : 490 €/mois. Revenu annuel brut : 4 410 €. Abattement micro-BIC 50% : base imposable 2 205 €. Gain fiscal vs nu : ~300 €/an pour un foyer à 30%.</p>
      </div>
      <div class="border-l-4 border-emerald-400 pl-4">
        <p class="font-bold text-gray-900 mb-1">46 m² rénové, centre Nancy, régime réel simplifié</p>
        <p class="text-base text-gray-600 leading-relaxed">Loyer meublé : 620 €/mois. Revenus bruts : 7 440 €. Charges déductibles : 3 200 €. Amortissement du bien sur 30 ans : ~3 000 €/an. Résultat fiscal négatif les 10 premières années — aucun impôt sur les revenus locatifs.</p>
      </div>
      <div class="border-l-4 border-emerald-400 pl-4">
        <p class="font-bold text-gray-900 mb-1">T3 65 m², Vandœuvre-lès-Nancy, colocation meublée</p>
        <p class="text-base text-gray-600 leading-relaxed">3 chambres louées séparément à 350 €/chambre. Total : 1 050 €/mois vs 750 € en location classique. Rendement brut de 7,5% vs 5,4% en nu.</p>
      </div>
    </div>
  </div>

"""
anchor = '  <div class="text-xs text-gray-400 space-y-1">'
if anchor in c:
    c = c.replace(anchor, bloc + anchor)
    with open(path, "w") as f: f.write(c)
    print("✅ location_meublee — exemples injectés")
else:
    print("⚠️  anchor non trouvé dans location_meublee")
EOF
fi

# ─────────────────────────────────────────────
# 4. amenagement_combles — exemples avant Sources
# ─────────────────────────────────────────────
if grep -q "border-l-4" app/views/pages/amenagement_combles.html.erb; then
  echo "⏭  amenagement_combles — exemples déjà présents"
else
python3 << 'EOF'
path = "app/views/pages/amenagement_combles.html.erb"
with open(path) as f: c = f.read()
bloc = """  <div class="bg-white border border-gray-200 rounded-2xl p-6 mb-6">
    <h2 class="text-xl font-bold text-gray-900 mb-5">💡 Trois exemples concrets</h2>
    <div class="space-y-5">
      <div class="border-l-4 border-blue-400 pl-4">
        <p class="font-bold text-gray-900 mb-1">Maison 80 m² à Nancy-Ville-Vieille, charpente traditionnelle</p>
        <p class="text-base text-gray-600 leading-relaxed">Combles perdus de 40 m², hauteur sous faîtage 2,40 m. Aménagement en chambre + bureau : 32 m² créés. Coût total : 38 000 €. Valeur avant : 195 000 €. Après travaux : ~235 000 €. Plus-value nette : +42 000 € pour 38 000 € investis.</p>
      </div>
      <div class="border-l-4 border-blue-400 pl-4">
        <p class="font-bold text-gray-900 mb-1">Maison 1948, 46 m², impasse Canal Nancy</p>
        <p class="text-base text-gray-600 leading-relaxed">Hauteur sous faîtage : 2,10 m sur 12 m². Création d'un espace bureau-mezzanine de 10 m² utiles. Coût estimé 12 000 – 18 000 €. Gain DPE si isolation sarking incluse : passage de F à D possible.</p>
      </div>
      <div class="border-l-4 border-blue-400 pl-4">
        <p class="font-bold text-gray-900 mb-1">Maison années 60, Maxéville, conversion en T4</p>
        <p class="text-base text-gray-600 leading-relaxed">Combles de 55 m² avec fermettes industrielles. Renforcement charpente : 8 000 €. Aménagement 35 m² : 42 000 €. Total : 50 000 €. Passage de T3 à T4+, gain locatif de 180 €/mois. Retour sur investissement : ~23 ans.</p>
      </div>
    </div>
  </div>

"""
anchor = '  <div class="text-xs text-gray-400 space-y-1">'
if anchor in c:
    c = c.replace(anchor, bloc + anchor)
    with open(path, "w") as f: f.write(c)
    print("✅ amenagement_combles — exemples injectés")
else:
    print("⚠️  anchor non trouvé dans amenagement_combles")
EOF
fi

# ─────────────────────────────────────────────
# 5. espace_exterieur — exemples avant Sources
# ─────────────────────────────────────────────
if grep -q "border-l-4" app/views/pages/espace_exterieur.html.erb; then
  echo "⏭  espace_exterieur — exemples déjà présents"
else
python3 << 'EOF'
path = "app/views/pages/espace_exterieur.html.erb"
with open(path) as f: c = f.read()
bloc = """  <div class="bg-white border border-gray-200 rounded-2xl p-6 mb-6">
    <h2 class="text-xl font-bold text-gray-900 mb-5">💡 Trois exemples concrets</h2>
    <div class="space-y-5">
      <div class="border-l-4 border-green-400 pl-4">
        <p class="font-bold text-gray-900 mb-1">Cour pavée 25 m², impasse Nancy centre</p>
        <p class="text-base text-gray-600 leading-relaxed">Terrasse bois + jardinières + éclairage LED solaire. Budget : 3 200 €. Le bien loué 580 €/mois part à 660 €/mois après travaux — +80 €/mois, soit +960 €/an. Retour sur investissement : 3,3 ans.</p>
      </div>
      <div class="border-l-4 border-green-400 pl-4">
        <p class="font-bold text-gray-900 mb-1">Jardin 80 m², maison Jarville-la-Malgrange</p>
        <p class="text-base text-gray-600 leading-relaxed">Potager en carrés, abri bois 4 m², clôture végétale. Budget : 4 500 €. Deux estimateurs notariaux ont relevé un gain de +8 000 € sur le prix de vente vs biens comparables sans extérieur soigné.</p>
      </div>
      <div class="border-l-4 border-green-400 pl-4">
        <p class="font-bold text-gray-900 mb-1">Parking 2 places, maison Vandœuvre</p>
        <p class="text-base text-gray-600 leading-relaxed">Rénovation revêtement + portail motorisé + borne 7 kW. Budget : 6 800 €. La place se loue 80 €/mois à un voisin (960 €/an). La borne facilite la location aux télétravailleurs avec véhicule électrique.</p>
      </div>
    </div>
  </div>

"""
anchor = '  <div class="text-xs text-gray-400 space-y-1">'
if anchor in c:
    c = c.replace(anchor, bloc + anchor)
    with open(path, "w") as f: f.write(c)
    print("✅ espace_exterieur — exemples injectés")
else:
    print("⚠️  anchor non trouvé dans espace_exterieur")
EOF
fi

# ─────────────────────────────────────────────
# 6. box_stockage — exemples avant </div> final
# ─────────────────────────────────────────────
if grep -q "border-l-4" app/views/pages/box_stockage.html.erb; then
  echo "⏭  box_stockage — exemples déjà présents"
else
python3 << 'EOF'
path = "app/views/pages/box_stockage.html.erb"
with open(path) as f: c = f.read()
bloc = """
  <div class="bg-white border border-gray-200 rounded-2xl p-6 mb-6">
    <h2 class="text-xl font-bold text-gray-900 mb-5">💡 Trois exemples concrets</h2>
    <div class="space-y-5">
      <div class="border-l-4 border-amber-400 pl-4">
        <p class="font-bold text-gray-900 mb-1">Cave 8 m², immeuble centre Nancy</p>
        <p class="text-base text-gray-600 leading-relaxed">Nettoyage + étagères + serrure renforcée : 380 €. Location sur Jestocke : 45 €/mois. Revenu net annuel : 540 €. Retour sur investissement : 8 mois.</p>
      </div>
      <div class="border-l-4 border-amber-400 pl-4">
        <p class="font-bold text-gray-900 mb-1">Garage fermé 18 m², maison Tomblaine</p>
        <p class="text-base text-gray-600 leading-relaxed">Location à un artisan plombier : 110 €/mois. Revenu annuel : 1 320 €. Après abattement micro-BIC : coût fiscal ~198 €/an. Revenu net d'impôt : ~1 122 €/an sans aucun travaux.</p>
      </div>
      <div class="border-l-4 border-amber-400 pl-4">
        <p class="font-bold text-gray-900 mb-1">Abri bois 12 m² construit, Laxou</p>
        <p class="text-base text-gray-600 leading-relaxed">Construction < 20 m² (déclaration préalable). Coût : 3 800 €. Loué à deux voisins à 70 €/mois chacun. Revenu : 1 680 €/an. Retour sur investissement : 2,3 ans.</p>
      </div>
    </div>
  </div>
"""
c = c.rstrip()
if c.endswith("</div>"):
    c = c[:-6] + bloc + "\n</div>\n"
    with open(path, "w") as f: f.write(c)
    print("✅ box_stockage — exemples injectés")
else:
    print("⚠️  fin de fichier inattendue dans box_stockage")
EOF
fi

# ─────────────────────────────────────────────
# Vérification finale
# ─────────────────────────────────────────────
echo ""
echo "📊 Vérification finale :"
for page in panneaux_solaires location_meublee amenagement_combles espace_exterieur box_stockage; do
  count=$(grep -c "border-l-4" app/views/pages/${page}.html.erb 2>/dev/null || echo "0")
  echo "  ${page} : ${count} exemples"
done
grep "En savoir plus" app/views/properties/show.html.erb | head -1
