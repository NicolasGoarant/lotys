# Seeds de démo pour la carte des biens publiés (home + page artisans).
#
# Contexte : un User.destroy_all sur des comptes de test a supprimé en cascade
# (dependent: :destroy → User → Property → analysis/valuation/offers…) les biens
# qui alimentaient les marqueurs Leaflet. Cette tâche recrée un jeu de démo
# stable, possédé par un utilisateur dédié (demo@lauze.eu) qui n'a aucune
# raison d'être inclus dans un balayage des "comptes de test".
#
# Idempotente :
#   - User trouvé par email, créé si absent (confirmé immédiatement).
#   - Chaque bien identifié par (user, address). Re-rejouer la tâche
#     met à jour les attributs sans dupliquer ni détruire d'enregistrement.
#
# Visibilité : status = :published ⇒ visible à la fois
#   - sur la carte home/artisans (scope `status IN [:analyzed, :published]`,
#     cf. PagesController#home + #artisans),
#   - et dans la liste prestataires (`Property.published`,
#     cf. OffersController#index).
#
# Coordonnées renseignées manuellement (pas d'appel BAN) + code_insee depuis
# GrandNancy::COMMUNES → active les aides territoriales Grand Nancy sans
# dépendre du réseau au moment du seed.
#
# Usage : `rails demo:seed` (ou `bin/rails demo:seed`)

require_relative "../grand_nancy"

namespace :demo do
  DEMO_EMAIL    = "demo@lauze.eu".freeze
  DEMO_PASSWORD = "DemoLauze2026!".freeze
  DEMO_SOURCE   = "demo".freeze

  # Code postal par code INSEE (10 communes utilisées). Le CP n'est pas dans
  # GrandNancy::COMMUNES, on le tient ici pour rester autonome.
  ZIPCODES = {
    "54395" => "54000", # Nancy
    "54547" => "54500", # Vandœuvre-lès-Nancy
    "54304" => "54520", # Laxou
    "54357" => "54320", # Maxéville
    "54526" => "54510", # Tomblaine
    "54578" => "54600", # Villers-lès-Nancy
    "54482" => "54130", # Saint-Max
    "54274" => "54140", # Jarville-la-Malgrange
    "54339" => "54220", # Malzéville
    "54184" => "54270"  # Essey-lès-Nancy
  }.freeze

  # 10 biens réalistes répartis sur la métropole. Mix maison/appartement,
  # DPE E→G (la cible naturelle d'une plateforme rénovation), surfaces et
  # années cohérentes (parc construit avant 1990, gros besoin de travaux).
  BIENS = [
    { insee: "54395", address: "14 rue Saint-Georges",          dpe: "G", surface: 58,  type: "appartement", rooms: 2, year: 1952, income: "modeste",       travaux: %i[isolation_toiture chauffage menuiseries] },
    { insee: "54547", address: "27 avenue Jeanne d'Arc",        dpe: "F", surface: 92,  type: "maison",      rooms: 4, year: 1968, income: "intermediaire", travaux: %i[isolation_toiture isolation_murs chauffage] },
    { insee: "54304", address: "8 rue de la Meuse",             dpe: "E", surface: 74,  type: "appartement", rooms: 3, year: 1974, income: "intermediaire", travaux: %i[chauffage vmc menuiseries] },
    { insee: "54357", address: "12 rue de Metz",                dpe: "G", surface: 110, type: "maison",      rooms: 5, year: 1948, income: "modeste",       travaux: %i[isolation_toiture isolation_murs chauffage menuiseries] },
    { insee: "54526", address: "5 rue de la République",        dpe: "F", surface: 88,  type: "maison",      rooms: 4, year: 1962, income: "intermediaire", travaux: %i[isolation_toiture chauffage chauffe_eau] },
    { insee: "54578", address: "19 boulevard de Lorraine",      dpe: "E", surface: 63,  type: "appartement", rooms: 3, year: 1981, income: "intermediaire", travaux: %i[chauffage menuiseries] },
    { insee: "54482", address: "3 rue Anatole France",          dpe: "G", surface: 52,  type: "appartement", rooms: 2, year: 1930, income: "tres_modeste",  travaux: %i[isolation_toiture isolation_murs chauffage menuiseries vmc] },
    { insee: "54274", address: "22 rue de la Malgrange",        dpe: "F", surface: 135, type: "maison",      rooms: 5, year: 1955, income: "intermediaire", travaux: %i[isolation_toiture isolation_murs chauffage] },
    { insee: "54339", address: "9 rue du Général de Gaulle",    dpe: "E", surface: 79,  type: "maison",      rooms: 4, year: 1971, income: "intermediaire", travaux: %i[isolation_toiture chauffage vmc] },
    { insee: "54184", address: "16 avenue Foch",                dpe: "F", surface: 45,  type: "appartement", rooms: 2, year: 1958, income: "modeste",       travaux: %i[isolation_toiture chauffage menuiseries] }
  ].freeze

  # Coordonnées centrales fournies par le brief — utilisées telles quelles ;
  # pour la carte, une précision "centre de commune" est suffisante.
  COORDS = {
    "54395" => [48.6921, 6.1844], # Nancy
    "54547" => [48.6578, 6.1739], # Vandœuvre
    "54304" => [48.6847, 6.1456], # Laxou
    "54357" => [48.7128, 6.1656], # Maxéville
    "54526" => [48.6889, 6.2147], # Tomblaine
    "54578" => [48.6711, 6.1500], # Villers
    "54482" => [48.7008, 6.2056], # Saint-Max
    "54274" => [48.6694, 6.2017], # Jarville
    "54339" => [48.7142, 6.1825], # Malzéville
    "54184" => [48.7050, 6.2256]  # Essey
  }.freeze

  desc "(Re)crée le user demo@lauze.eu et 10 biens publiés sur le Grand Nancy"
  task seed: :environment do
    abort "GrandNancy module manquant" unless defined?(GrandNancy)

    demo_user = User.find_by(email: DEMO_EMAIL) || User.new(email: DEMO_EMAIL)
    if demo_user.new_record?
      demo_user.password              = DEMO_PASSWORD
      demo_user.password_confirmation = DEMO_PASSWORD
      demo_user.role                  = :proprietaire
      demo_user.confirmed_at          = Time.current
      demo_user.save!
      puts "✅ User demo créé : #{demo_user.email} (id=#{demo_user.id})"
    else
      # Resté confirmé / proprietaire même si quelqu'un a fiddle dans la DB.
      attrs = {}
      attrs[:confirmed_at] = Time.current if demo_user.confirmed_at.nil?
      attrs[:role] = :proprietaire        unless demo_user.proprietaire?
      demo_user.update!(attrs) if attrs.any?
      puts "↺  User demo réutilisé : #{demo_user.email} (id=#{demo_user.id})"
    end

    crees, maj = 0, 0
    BIENS.each do |b|
      insee = b[:insee]
      lat, lng = COORDS.fetch(insee)
      city  = GrandNancy::COMMUNES.fetch(insee)
      zip   = ZIPCODES.fetch(insee)

      # Clé d'idempotence : (user, address) — unique en pratique vu le mix
      # d'adresses + permet de re-rejouer en mettant juste à jour les champs.
      bien = Property.find_or_initialize_by(user: demo_user, address: b[:address])
      nouveau = bien.new_record?

      bien.assign_attributes(
        city:              city,
        zipcode:           zip,
        lat:               lat,
        lng:               lng,
        code_insee:        insee,
        dpe_class:         b[:dpe],
        dpe_target:        { "G" => "C", "F" => "C", "E" => "D" }.fetch(b[:dpe]),
        surface:           b[:surface],
        property_type:     b[:type],
        nb_rooms:          b[:rooms],
        construction_year: b[:year],
        income_bracket:    b[:income],
        is_copropriete:    b[:type] == "appartement",
        status:            :published,
        source:            DEMO_SOURCE,
        travaux_selection: Property::TRAVAUX_BOOL_KEYS.each_with_object({}) { |k, h| h[k.to_s] = b[:travaux].include?(k) }
      )

      bien.save!
      nouveau ? crees += 1 : maj += 1
    end

    puts
    puts "Récapitulatif demo:seed"
    puts "-" * 78
    puts "  user           : #{demo_user.email} (id=#{demo_user.id}, role=#{demo_user.role})"
    puts "  biens créés    : #{crees}"
    puts "  biens MAJ      : #{maj}"
    puts "  total possédés : #{demo_user.properties.count}"
    puts

    # Vérif : les biens passent-ils le scope de la carte ?
    scope = Property.where(status: [:analyzed, :published])
                    .where.not(lat: nil, lng: nil)
                    .where(user_id: demo_user.id)
    puts "  visibles sur la carte (scope home/artisans) : #{scope.count}/#{demo_user.properties.count}"
    puts

    puts "id   | ville                      | cp    | dpe | surf | type        | status"
    puts "-" * 78
    demo_user.properties.order(:id).each do |p|
      puts "%-4d | %-26s | %-5s | %-3s | %4d | %-11s | %s" % [
        p.id, p.city.to_s[0, 26], p.zipcode, p.dpe_class, p.surface,
        p.property_type, p.status
      ]
    end
  end
end
