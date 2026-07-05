# Feature portail EPCI — seed idempotent des collectivités portail.
#
# Rejouable à volonté (find_or_create_by sur le slug), ne détruit
# jamais de donnée existante. Le welcome_text et primary_color sont
# posés par défaut à la création ; les MISES À JOUR ultérieures via
# rails console sont préservées (on ne re-force pas les champs
# éditables au ré-exécution).
#
# Le logo n'est PAS pré-attaché. À poser à la main :
#   heroku run rails c -a lauze
#     c = Collectivite.find_by(slug: "grand-nancy")
#     c.logo.attach(io: File.open("logo.png"), filename: "logo.png")
#
# Le fallback initiales (Collectivite#initiales) permet de montrer la
# démo avant que le logo n'arrive.
namespace :collectivites do
  desc "Seed les collectivités portail (idempotent, préserve les édits admin)"
  task seed: :environment do
    require_relative "../grand_nancy"

    grand_nancy = Collectivite.find_or_initialize_by(slug: "grand-nancy")
    if grand_nancy.new_record?
      grand_nancy.assign_attributes(
        name:          "Métropole du Grand Nancy",
        primary_color: "#0066a1",
        welcome_text:  "Bienvenue habitants du Grand Nancy. " \
                       "Estimez votre projet de rénovation en quelques clics — " \
                       "les aides MaPrimeRénov', CEE et celles de la Métropole " \
                       "sont calculées automatiquement.",
        insee_codes:   GrandNancy::COMMUNE_INSEE_CODES.dup,
        active:        true
      )
      grand_nancy.save!
      puts "✓ Collectivite créée : #{grand_nancy.name} (#{grand_nancy.slug}) — " \
           "#{grand_nancy.insee_codes.size} communes"
    else
      # Sync SEULEMENT le périmètre insee_codes contre la source de
      # vérité GrandNancy (si l'EPCI change de composition, on veut
      # que le portail suive). Les autres champs (welcome_text,
      # primary_color) restent éditables sans risque d'être écrasés.
      expected = GrandNancy::COMMUNE_INSEE_CODES.sort
      current  = Array(grand_nancy.insee_codes).sort
      if expected != current
        grand_nancy.update!(insee_codes: GrandNancy::COMMUNE_INSEE_CODES.dup)
        puts "↻ #{grand_nancy.slug} : insee_codes resynchronisés depuis GrandNancy " \
             "(#{expected.size} communes)"
      else
        puts "= #{grand_nancy.slug} déjà à jour (#{current.size} communes)"
      end
    end
  end
end
