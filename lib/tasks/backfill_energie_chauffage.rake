# Backfill energie_chauffage sur les Property antérieurs à la migration.
# Wrapper minimal autour de EnergieChauffageBackfillService — toute la
# logique (et ses tests) est dans le service.
#
# Usage : bin/rake lauze:backfill_energie_chauffage
# Idempotent : relancer ne change rien au second passage.

namespace :lauze do
  desc "Backfill Property#energie_chauffage via HeatingEnergyNormalizer (idempotent)"
  task backfill_energie_chauffage: :environment do
    puts "═" * 70
    puts " Backfill energie_chauffage — démarre"
    puts "═" * 70

    rapport = EnergieChauffageBackfillService.call

    puts
    printf "  Scannés                          : %3d\n", rapport[:scannes]
    printf "  → basculés vers une énergie typée : %3d\n", rapport[:basculs].size
    printf "  → inchangés (source ≥ extrait)    : %3d\n", rapport[:inchanges_source_plus_fiable].size
    printf "  → restent :inconnue (pas de signal): %3d\n", rapport[:restent_inconnues].size

    if rapport[:basculs].any?
      puts
      puts "  ─── Détail des bascules ──────────────────────────────────────────"
      rapport[:basculs].each do |b|
        libelle = b[:libelle_matche].to_s.gsub(/\s+/, " ").strip
        printf "    ID %3d  → :%-12s  depuis « %s »\n",
               b[:id], b[:energie], libelle.length > 50 ? "#{libelle[0, 50]}…" : libelle
      end
    end

    if rapport[:inchanges_source_plus_fiable].any?
      puts
      puts "  ─── Sources plus fiables préservées ──────────────────────────────"
      rapport[:inchanges_source_plus_fiable].each do |h|
        printf "    ID %3d  source=:%s (préservé)\n", h[:id], h[:source_actuelle]
      end
    end

    puts
    puts "═" * 70
  end
end
