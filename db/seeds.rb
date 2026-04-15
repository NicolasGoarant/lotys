puts "Nettoyage des seeds précédents..."
Property.where(source: "seed").each(&:destroy)
User.where(email: "demo@lotys.fr").destroy_all

# Utilisateur démo
user = User.create!(
  email: "demo@lotys.fr",
  password: "password123",
  password_confirmation: "password123",
  role: :proprietaire
)

biens = [
  { address: "14 rue Saint-Georges",               city: "Nancy", zipcode: "54000", lat: 48.6909, lng: 6.1831, dpe: "G", surface: 58,  type: "appartement", rooms: 2, year: 1952 },
  { address: "3 rue des Lilas",                    city: "Nancy", zipcode: "54000", lat: 48.6650, lng: 6.1750, dpe: "F", surface: 92,  type: "maison",       rooms: 4, year: 1968 },
  { address: "7 avenue du Général Leclerc",        city: "Nancy", zipcode: "54000", lat: 48.6880, lng: 6.1650, dpe: "E", surface: 74,  type: "appartement", rooms: 3, year: 1974 },
  { address: "8 rue de la Craffe",                 city: "Nancy", zipcode: "54000", lat: 48.6980, lng: 6.1760, dpe: "G", surface: 45,  type: "appartement", rooms: 2, year: 1930 },
  { address: "31 rue du Faubourg des Trois-Maisons", city: "Nancy", zipcode: "54000", lat: 48.6750, lng: 6.2010, dpe: "F", surface: 110, type: "maison",    rooms: 5, year: 1962 },
  { address: "5 rue Isabey",                       city: "Nancy", zipcode: "54000", lat: 48.6860, lng: 6.1890, dpe: "E", surface: 63,  type: "appartement", rooms: 3, year: 1981 },
  { address: "19 boulevard d'Austrasie",           city: "Nancy", zipcode: "54000", lat: 48.7010, lng: 6.1770, dpe: "F", surface: 88,  type: "maison",       rooms: 4, year: 1955 },
  { address: "22 rue Charles III",                 city: "Nancy", zipcode: "54000", lat: 48.6935, lng: 6.1812, dpe: "G", surface: 52,  type: "appartement", rooms: 2, year: 1948 },
  { address: "4 rue de Metz",                      city: "Nancy", zipcode: "54000", lat: 48.6897, lng: 6.1773, dpe: "F", surface: 79,  type: "appartement", rooms: 3, year: 1967 },
  { address: "11 rue de la Pépinière",             city: "Nancy", zipcode: "54000", lat: 48.6952, lng: 6.1838, dpe: "E", surface: 135, type: "maison",       rooms: 5, year: 1971 },
]

puts "Création de #{biens.size} biens..."
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
  puts "  ✅ #{p.address} — DPE #{p.dpe_class}"
end

puts "\n✅ #{Property.where(source: 'seed').count} biens seed créés"
