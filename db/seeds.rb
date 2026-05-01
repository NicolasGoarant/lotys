puts "Nettoyage des seeds précédents..."
Property.where(source: "seed").each(&:destroy)
User.where(email: "demo@lauze.fr").destroy_all

user = User.create!(
  email: "demo@lauze.fr",
  password: "password123",
  password_confirmation: "password123",
  role: :proprietaire
)

biens = [
  { address: "14 rue Saint-Georges",                city: "Nancy", zipcode: "54000", lat: 48.6909, lng: 6.1831, dpe: "G", surface: 58,  type: "appartement", rooms: 2, year: 1952 },
  { address: "3 rue des Lilas",                     city: "Nancy", zipcode: "54000", lat: 48.6650, lng: 6.1750, dpe: "F", surface: 92,  type: "maison",       rooms: 4, year: 1968 },
  { address: "7 avenue du Général Leclerc",         city: "Nancy", zipcode: "54000", lat: 48.6880, lng: 6.1650, dpe: "E", surface: 74,  type: "appartement", rooms: 3, year: 1974 },
  { address: "8 rue de la Craffe",                  city: "Nancy", zipcode: "54000", lat: 48.6980, lng: 6.1760, dpe: "G", surface: 45,  type: "appartement", rooms: 2, year: 1930 },
  { address: "31 rue du Faubourg des Trois-Maisons",city: "Nancy", zipcode: "54000", lat: 48.6750, lng: 6.2010, dpe: "F", surface: 110, type: "maison",       rooms: 5, year: 1962 },
  { address: "5 rue Isabey",                        city: "Nancy", zipcode: "54000", lat: 48.6860, lng: 6.1890, dpe: "E", surface: 63,  type: "appartement", rooms: 3, year: 1981 },
  { address: "19 boulevard d'Austrasie",            city: "Nancy", zipcode: "54000", lat: 48.7010, lng: 6.1770, dpe: "F", surface: 88,  type: "maison",       rooms: 4, year: 1955 },
  { address: "22 rue Charles III",                  city: "Nancy", zipcode: "54000", lat: 48.6935, lng: 6.1812, dpe: "G", surface: 52,  type: "appartement", rooms: 2, year: 1948 },
  { address: "4 rue de Metz",                       city: "Nancy", zipcode: "54000", lat: 48.6897, lng: 6.1773, dpe: "F", surface: 79,  type: "appartement", rooms: 3, year: 1967 },
  { address: "11 rue de la Pépinière",              city: "Nancy", zipcode: "54000", lat: 48.6952, lng: 6.1838, dpe: "E", surface: 135, type: "maison",       rooms: 5, year: 1971 },
]

def travaux_pour(dpe, type)
  base = [
    { "poste" => "Isolation des combles ou toiture", "priorite" => 1, "cout_min" => 3000, "cout_max" => 8000 },
    { "poste" => "Isolation des murs par l'extérieur ou l'intérieur", "priorite" => 2, "cout_min" => 8000, "cout_max" => 20000 },
    { "poste" => "Remplacement du système de chauffage (pompe à chaleur ou chaudière à condensation)", "priorite" => 3, "cout_min" => 6000, "cout_max" => 14000 },
  ]
  base << { "poste" => "Remplacement des fenêtres (double vitrage haute performance)", "priorite" => 4, "cout_min" => 4000, "cout_max" => 10000 } if dpe == "G"
  base
end

def analyse_json(bien)
  dpe_cible = { "G" => "C", "F" => "C", "E" => "D" }[bien[:dpe]]
  travaux = travaux_pour(bien[:dpe], bien[:type])
  budget_min = travaux.sum { |t| t["cout_min"] }
  budget_max = travaux.sum { |t| t["cout_max"] }
  valeur_base = bien[:type] == "maison" ? 1800 : 1600
  valeur = (valeur_base * bien[:surface] * (bien[:dpe] == "G" ? 0.82 : bien[:dpe] == "F" ? 0.90 : 0.95)).round(-3)

  {
    "valeur" => {
      "estimation_centrale" => valeur,
      "estimation_basse"    => (valeur * 0.90).round(-3),
      "estimation_haute"    => (valeur * 1.10).round(-3),
      "prix_acquisition"    => nil
    },
    "energie" => {
      "dpe_estime"  => bien[:dpe],
      "dpe_cible"   => dpe_cible,
      "travaux"     => travaux,
      "budget_min"  => budget_min,
      "budget_max"  => budget_max
    },
    "idees" => {
      "scenarios" => [
        { "emoji" => "☀️", "titre" => "Installation de panneaux solaires", "gain_estime" => "800€/an" },
        { "emoji" => "🏠", "titre" => "Aménagement des combles en espace habitable", "gain_estime" => "+15% valeur" }
      ]
    },
    "recommandation" => "Priorité aux travaux d'isolation pour sortir du statut passoire thermique et retrouver la capacité locative."
  }.to_json
end

puts "Création de #{biens.size} biens avec analyses..."
biens.each do |b|
  dpe_target = { "G" => "C", "F" => "C", "E" => "D" }[b[:dpe]]
  p = user.properties.create!(
    address:           b[:address],
    city:              b[:city],
    zipcode:           b[:zipcode],
    lat:               b[:lat],
    lng:               b[:lng],
    dpe_class:         b[:dpe],
    dpe_target:        dpe_target,
    surface:           b[:surface],
    property_type:     b[:type],
    nb_rooms:          b[:rooms],
    construction_year: b[:year],
    status:            :published,
    source:            "seed",
    income_bracket:    "intermediaire",
    is_copropriete:    b[:type] == "appartement"
  )

  p.create_analysis!(
    analysis_type: "full",
    status:        2,
    content:       analyse_json(b)
  )

  puts "  ✅ #{p.address} — DPE #{p.dpe_class}"
end

puts "\n✅ #{Property.where(source: 'seed').count} biens créés avec analyses"
EOF~
