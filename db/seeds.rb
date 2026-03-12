puts "🌱 Nettoyage..."
Offer.destroy_all
Document.destroy_all
DeviceSimulation.destroy_all
Valuation.destroy_all
Analysis.destroy_all
Property.destroy_all
User.destroy_all

puts "👤 Création des users..."

nicolas = User.create!(email: "nicolas@lotys.fr",        password: "password123", role: :proprietaire)
marie   = User.create!(email: "marie.dupont@gmail.com",  password: "password123", role: :proprietaire)
pierre  = User.create!(email: "pierre.martin@gmail.com", password: "password123", role: :proprietaire)
helene  = User.create!(email: "helene.roussel@gmail.com",password: "password123", role: :proprietaire)

artisan  = User.create!(email: "ruddy@isolexpert.fr",        password: "password123", role: :prestataire)
courtier = User.create!(email: "sophie.courtier@pretto.fr",  password: "password123", role: :prestataire)
promoteur = User.create!(email: "dev@angelotti-immo.fr",     password: "password123", role: :prestataire)

puts "🏠 Création des biens..."

# 1 — Nancy centre, DPE G, copropriété 5 lots, publié
p1 = Property.create!(
  user: nicolas, address: "14 rue Saint-Georges", city: "Nancy", zipcode: "54000",
  surface: 68, property_type: "appartement", construction_year: 1923,
  dpe_class: "G", nb_rooms: 3, nb_lots: 5, is_copropriete: true,
  description: "Appartement hérité de ma grand-mère. Chauffage au fioul collectif. Je veux comprendre s'il vaut mieux rénover ou vendre — et si une vente groupée avec les voisins serait intéressante.",
  status: :published
)
Valuation.create!(property: p1, estimated_value: 98_000, min_value: 88_000, max_value: 108_000, bulk_sale_estimate: 135_000, methodology: "23 ventes comparables DVF", dvf_raw: { avg_price_sqm: 1441, sample_size: 23 }, comparable_sales: [])
DeviceSimulation.create!(property: p1, eligible_eco_ptz: true, eco_ptz_max_amount: 50_000, eligible_maprimrenov: true, maprimrenov_amount: 14_600, eligible_cee: true, cee_estimated_amount: 1_530, total_aid_estimate: 66_130, notes: "DPE G : isolation prioritaire.", simulation_data: {})
Analysis.create!(property: p1, analysis_type: "global", content: "SITUATION ACTUELLE\nPassoire thermique classée G. Copropriété de 5 lots, construit en 1923.\n\nSCÉNARIO RÉNOVER\nIsolation + PAC. Aides jusqu'à 66 130€. Reste à charge quasi nul.\n\nSCÉNARIO VENDRE\nValeur actuelle : 98 000€ avec décote DPE G.\n\nSCÉNARIO VENTE EN BLOC\nPotentiel 135 000€ avec accord unanime des 5 copropriétaires.\n\nRECOMMANDATION\nExplorer la vente en bloc en priorité.", status: 1)

# 2 — Nancy Haussonville, DPE E, maison, analysé
p2 = Property.create!(
  user: marie, address: "7 avenue du Général Leclerc", city: "Nancy", zipcode: "54000",
  surface: 112, property_type: "maison", construction_year: 1968,
  dpe_class: "E", nb_rooms: 5, nb_lots: 1, is_copropriete: false,
  description: "Maison familiale. On envisage de la mettre en location. Avec le DPE E, on hésite — rénover avant ou vendre maintenant ?",
  status: :analyzed
)
Valuation.create!(property: p2, estimated_value: 245_000, min_value: 220_000, max_value: 270_000, bulk_sale_estimate: nil, methodology: "31 ventes comparables DVF", dvf_raw: { avg_price_sqm: 2187, sample_size: 31 }, comparable_sales: [])
DeviceSimulation.create!(property: p2, eligible_eco_ptz: true, eco_ptz_max_amount: 50_000, eligible_maprimrenov: true, maprimrenov_amount: 8_600, eligible_cee: true, cee_estimated_amount: 2_520, total_aid_estimate: 61_120, notes: "DPE E : éligible MaPrimeRénov'. Interdiction de louer en 2028.", simulation_data: {})

# 3 — Vandœuvre, DPE F, copropriété, publié
p3 = Property.create!(
  user: pierre, address: "3 rue des Lilas", city: "Vandœuvre-lès-Nancy", zipcode: "54500",
  surface: 55, property_type: "appartement", construction_year: 1975,
  dpe_class: "F", nb_rooms: 2, nb_lots: 12, is_copropriete: true,
  description: "Appartement locatif classé F. Le locataire part en juin. Je cherche des devis rénovation ou une offre d'achat.",
  status: :published
)
Valuation.create!(property: p3, estimated_value: 72_000, min_value: 65_000, max_value: 80_000, bulk_sale_estimate: nil, methodology: "18 ventes comparables DVF", dvf_raw: { avg_price_sqm: 1309, sample_size: 18 }, comparable_sales: [])
DeviceSimulation.create!(property: p3, eligible_eco_ptz: true, eco_ptz_max_amount: 50_000, eligible_maprimrenov: true, maprimrenov_amount: 11_800, eligible_cee: true, cee_estimated_amount: 1_238, total_aid_estimate: 63_038, notes: "DPE F : interdiction de louer en 2028.", simulation_data: {})

# 4 — Nancy Trois-Maisons, DPE G, copropriété 4 lots, publié
p4 = Property.create!(
  user: helene, address: "31 rue du Faubourg des Trois-Maisons", city: "Nancy", zipcode: "54000",
  surface: 78, property_type: "appartement", construction_year: 1910,
  dpe_class: "G", nb_rooms: 4, nb_lots: 4, is_copropriete: true,
  description: "Succession. Trois héritiers, on doit décider ensemble. Le bien est occupé jusqu'en septembre. On cherche à comprendre la valeur réelle et les options.",
  status: :published
)
Valuation.create!(property: p4, estimated_value: 112_000, min_value: 100_000, max_value: 124_000, bulk_sale_estimate: 158_000, methodology: "19 ventes comparables DVF", dvf_raw: { avg_price_sqm: 1436, sample_size: 19 }, comparable_sales: [])
DeviceSimulation.create!(property: p4, eligible_eco_ptz: true, eco_ptz_max_amount: 50_000, eligible_maprimrenov: true, maprimrenov_amount: 16_800, eligible_cee: true, cee_estimated_amount: 1_755, total_aid_estimate: 68_555, notes: "DPE G, construit en 1910. Travaux d'isolation prioritaires.", simulation_data: {})
Analysis.create!(property: p4, analysis_type: "global", content: "SITUATION ACTUELLE\nBien en succession, 4 lots en copropriété. DPE G, construit en 1910.\n\nSCÉNARIO VENTE EN BLOC\nVente à un promoteur envisageable : 158 000€ estimés. Quartier Trois-Maisons en tension foncière.\n\nRECOMMANDATION\nVente en bloc prioritaire compte tenu du contexte successoral.", status: 1)

# 5 — Nancy Vieille-Ville, DPE F, maison, publié
p5 = Property.create!(
  user: nicolas, address: "8 rue de la Craffe", city: "Nancy", zipcode: "54000",
  surface: 145, property_type: "maison", construction_year: 1887,
  dpe_class: "F", nb_rooms: 6, nb_lots: 1, is_copropriete: false,
  description: "Maison de ville dans la Vieille-Ville. Beau volume, mais chauffage et isolation à reprendre entièrement. Je cherche un promoteur ou un investisseur.",
  status: :published
)
Valuation.create!(property: p5, estimated_value: 385_000, min_value: 350_000, max_value: 420_000, bulk_sale_estimate: nil, methodology: "12 ventes comparables DVF", dvf_raw: { avg_price_sqm: 2655, sample_size: 12 }, comparable_sales: [])
DeviceSimulation.create!(property: p5, eligible_eco_ptz: true, eco_ptz_max_amount: 50_000, eligible_maprimrenov: true, maprimrenov_amount: 22_000, eligible_cee: true, cee_estimated_amount: 3_263, total_aid_estimate: 75_263, notes: "Surface importante : aides plafonnées mais CEE élevés.", simulation_data: {})

# 6 — Nancy, DPE D, appartement, publié
p6 = Property.create!(
  user: marie, address: "5 rue Isabey", city: "Nancy", zipcode: "54000",
  surface: 82, property_type: "appartement", construction_year: 1995,
  dpe_class: "D", nb_rooms: 4, nb_lots: 20, is_copropriete: true,
  description: "Je pars à l'étranger pour 3 ans. Je cherche à savoir s'il vaut mieux louer, vendre ou faire quelques travaux avant de décider.",
  status: :published
)
Valuation.create!(property: p6, estimated_value: 178_000, min_value: 162_000, max_value: 195_000, bulk_sale_estimate: nil, methodology: "27 ventes comparables DVF", dvf_raw: { avg_price_sqm: 2171, sample_size: 27 }, comparable_sales: [])
DeviceSimulation.create!(property: p6, eligible_eco_ptz: true, eco_ptz_max_amount: 50_000, eligible_maprimrenov: true, maprimrenov_amount: 3_000, eligible_cee: true, cee_estimated_amount: 1_845, total_aid_estimate: 54_845, notes: "DPE D : éligible aux aides, travaux non urgents.", simulation_data: {})

# 7 — Draft
p7 = Property.create!(
  user: pierre, address: "19 boulevard d'Austrasie", city: "Nancy", zipcode: "54000",
  surface: 95, property_type: "appartement", construction_year: 1932,
  dpe_class: "G", nb_rooms: 4, nb_lots: 6, is_copropriete: true,
  description: "En cours d'évaluation.",
  status: :draft
)

puts "💼 Création des offres..."

# Offres sur p1
Offer.create!(property: p1, user: artisan, offer_type: :renovation, amount: 38_500,
  description: "Isolation combles + remplacement chaudière fioul par PAC air/eau. Certifié RGE Qualibat. Accompagnement dossier MaPrimeRénov' inclus. Délai : 6 semaines.",
  status: :pending, expires_at: 30.days.from_now)
Offer.create!(property: p1, user: courtier, offer_type: :financement, amount: 50_000,
  description: "Éco-PTZ à 0% sur 15 ans, sans condition de ressources. Réponse de principe en 48h. Partenariat avec 12 banques.",
  status: :pending, expires_at: 30.days.from_now)
Offer.create!(property: p1, user: promoteur, offer_type: :achat_promoteur, amount: 130_000,
  description: "Offre d'achat en bloc pour les 5 lots de la copropriété, sous réserve d'accord unanime des copropriétaires. Projet de construction de 8 logements neufs. Délai de réalisation : 18 mois.",
  status: :pending, expires_at: 60.days.from_now)

# Offres sur p3
Offer.create!(property: p3, user: artisan, offer_type: :renovation, amount: 22_800,
  description: "ITE + remplacement menuiseries. Passage garanti F→C. Dossier CEE inclus.",
  status: :pending, expires_at: 30.days.from_now)

# Offres sur p4
Offer.create!(property: p4, user: promoteur, offer_type: :achat_promoteur, amount: 155_000,
  description: "Offre ferme pour les 4 lots, quartier Trois-Maisons. Projet résidentiel neuf BBC. Accompagnement notarial offert.",
  status: :pending, expires_at: 45.days.from_now)
Offer.create!(property: p4, user: courtier, offer_type: :financement, amount: 50_000,
  description: "Éco-PTZ disponible même en cas de succession. Montage juridique adapté aux situations de co-indivision.",
  status: :pending, expires_at: 30.days.from_now)

# Offres sur p5
Offer.create!(property: p5, user: promoteur, offer_type: :achat_promoteur, amount: 410_000,
  description: "Acquisition en vue de réhabilitation et division en 4 appartements. Offre sous 30 jours.",
  status: :pending, expires_at: 30.days.from_now)
Offer.create!(property: p5, user: artisan, offer_type: :renovation, amount: 68_000,
  description: "Rénovation thermique complète : isolation, menuiseries, VMC double-flux, poêle à granulés. Devis détaillé sur demande.",
  status: :pending, expires_at: 30.days.from_now)

puts "✅ Seeds terminés !"
puts ""
puts "📧 Comptes :"
puts "  Propriétaires : nicolas@lotys.fr · marie.dupont@gmail.com · pierre.martin@gmail.com · helene.roussel@gmail.com"
puts "  Prestataires  : ruddy@isolexpert.fr · sophie.courtier@pretto.fr · dev@angelotti-immo.fr"
puts "  Mot de passe  : password123"
