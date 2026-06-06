# Backfill du code INSEE sur les biens existants.
#
# La bascule du géocodeur sur l'API Adresse (BAN) introduit Property#code_insee.
# Les biens créés AVANT cette bascule ont code_insee NULL et perdent les aides
# territoriales (Grand Nancy) tant qu'ils ne sont pas re-géocodés.
#
# Cette tâche est idempotente : elle ne traite que les Properties dont
# code_insee est NULL. La rejouer après ajout de nouveaux biens (ou correction
# de GeocodingService) est sans effet de bord.

namespace :properties do
  desc "Backfill Property#code_insee via GeocodingService (BAN)"
  task backfill_code_insee: :environment do
    scope = Property.where(code_insee: nil)
    total = scope.count
    puts "Backfill code_insee — #{total} biens à traiter."
    puts

    rows = []
    scope.find_each do |p|
      avant = p.code_insee
      GeocodingService.new(p).call
      p.reload
      rows << {
        id: p.id,
        city: p.city,
        zipcode: p.zipcode,
        code_insee: p.code_insee,
        statut: avant == p.code_insee ? "inchangé" : "mis à jour"
      }
      # Politesse envers l'API publique BAN — 50 ms ≈ 20 req/s, large.
      sleep 0.05
    end

    puts "id   | ville                          | cp     | code_insee | statut"
    puts "-" * 78
    rows.each do |r|
      puts "%-4d | %-30s | %-6s | %-10s | %s" % [
        r[:id],
        (r[:city] || "")[0, 30],
        r[:zipcode] || "",
        r[:code_insee] || "(NULL)",
        r[:statut]
      ]
    end
    puts
    puts "Total traité : #{rows.size} | persistés : #{rows.count { |r| r[:code_insee] }} | encore NULL : #{rows.count { |r| r[:code_insee].nil? }}"
  end
end
