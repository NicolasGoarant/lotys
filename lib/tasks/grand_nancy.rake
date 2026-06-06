# Vérifie la composition de la Métropole du Grand Nancy contre l'API Géo Etalab
# et signale toute divergence avec lib/grand_nancy.rb.
#
# Usage : `rake grand_nancy:refresh`
#
# L'EPCI a pour SIREN 245400676. Si l'API renvoie un nombre différent de 20
# communes ou des codes INSEE qui ne correspondent pas, c'est qu'il y a eu un
# avenant : mettre à jour lib/grand_nancy.rb à la main avec la nouvelle liste.

namespace :grand_nancy do
  desc "Compare la composition de l'EPCI Grand Nancy à lib/grand_nancy.rb"
  task refresh: :environment do
    require "net/http"
    require "json"

    url = URI("https://geo.api.gouv.fr/epcis/245400676/communes?fields=nom,code")
    body = Net::HTTP.get(url)
    api  = JSON.parse(body)

    api_codes   = api.map { |c| c["code"] }.sort
    local_codes = GrandNancy::COMMUNE_INSEE_CODES.sort

    puts "API   : #{api.size} communes"
    puts "Local : #{local_codes.size} communes"

    missing = api_codes - local_codes
    extras  = local_codes - api_codes

    if missing.empty? && extras.empty?
      puts "✅ Composition locale identique à l'API (#{Time.now.strftime('%F')})."
    else
      puts "⚠ Divergence détectée — mettre à jour lib/grand_nancy.rb :"
      puts "  Manquants dans local : #{missing.inspect}"
      puts "  Extras dans local    : #{extras.inspect}"
      puts
      puts "Liste API (triée par code INSEE) :"
      api.sort_by { |c| c["code"] }.each { |c| puts "  #{c["code"]}  #{c["nom"]}" }
    end
  end
end
