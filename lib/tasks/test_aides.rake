# lib/tasks/test_aides.rake
#
# Filet anti-régression pour AidCalculatorService.
#
# Lance 4 à 6 scénarios types, construits 100 % en mémoire (Property.new
# non persisté), sans aucun appel à PropertyAnalysisService ni à une API
# externe. Pour chaque scénario, affiche un bloc lisible avec le détail
# dispositif par dispositif, le total des subventions, le financement
# éco-PTZ, et un statut DVF (disponible / indisponible) déterminé sans
# appel réseau (uniquement code_insee == "54395").
#
# Usage : bin/rails lauze:test_aides
#
# Aucune ligne n'est écrite en base.

namespace :lauze do
  desc "Filet anti-régression sur AidCalculatorService — 4 à 6 scénarios types"
  task test_aides: :environment do
    Aides::TestRunner.new.run
  end
end

module Aides
  class TestRunner
    SCENARIOS = [
      {
        titre: "Nancy G→C, très modeste — combles + ITE + PAC air/eau (par-geste)",
        property: {
          city: "Nancy", code_insee: "54395", property_type: "maison",
          surface: 110, construction_year: 1970,
          dpe_class: "G", dpe_target: "C", income_bracket: "tres_modeste",
          surface_combles_perdus: 80, surface_ite: 100, pac_air_eau: true,
          description: "isolation combles perdus + ITE + PAC air/eau"
        },
        attendus: %w[mpr_par_geste cee grand_nancy_isolation eco_ptz],
        # NB : pas de VMC → route vers par-geste (pas ampleur). Si tu veux
        # tester l'ampleur avec ce mix, ajoute vmc_double_flux: true.
        commentaire: "Sans VMC → par-geste, pas ampleur (eligible_parcours_accompagne? requiert ventilation)."
      },
      {
        titre: "Vandœuvre F→C, modeste — ITI + VMC double flux",
        property: {
          city: "Vandœuvre-lès-Nancy", code_insee: "54547", property_type: "maison",
          surface: 95, construction_year: 1968,
          dpe_class: "F", dpe_target: "C", income_bracket: "modeste",
          surface_iti: 70, vmc_double_flux: true,
          description: "ITI + VMC double flux"
        },
        # ITI n'a pas de forfait MPR par-geste (seules surface_rampants et
        # surface_toiture_terrasse en ont) → MPR par-geste ne portera que
        # sur la VMC. CEE idem.
        attendus: %w[mpr_par_geste cee grand_nancy_isolation eco_ptz],
        commentaire: "Hors Nancy mais dans Grand Nancy → GN Isolation OUI, DVF INDISPONIBLE."
      },
      {
        titre: "Lunéville E→C, intermédiaire — fenêtres + combles perdus (hors Grand Nancy)",
        property: {
          city: "Lunéville", code_insee: "54329", property_type: "maison",
          surface: 90, construction_year: 1965,
          dpe_class: "E", dpe_target: "C", income_bracket: "intermediaire",
          surface_combles_perdus: 60, nb_parois_vitrees: 8,
          description: "isolation combles perdus + remplacement fenêtres simple → double vitrage"
        },
        attendus: %w[mpr_par_geste cee eco_ptz],
        commentaire: "Hors Grand Nancy → aucune aide locale, DVF indisponible."
      },
      {
        titre: "Nancy F→D, supérieur — ITE seule",
        property: {
          city: "Nancy", code_insee: "54395", property_type: "maison",
          surface: 100, construction_year: 1970,
          dpe_class: "F", dpe_target: "D", income_bracket: "superieur",
          surface_ite: 100,
          description: "ITE seule"
        },
        # SUP : MPR par-geste vide par design (Fiche 07), donc ITE ne
        # déclenche aucun MPR. CEE sur ITE oui (BAR-EN-102, 12 €/m² en
        # SUP). GN Isolation refuse cible D (règlement Grand Nancy :
        # cible ≥ C requise).
        attendus: %w[cee eco_ptz],
        non_attendus: %w[mpr_par_geste grand_nancy_isolation],
        commentaire: "Monogeste MPR exclu en SUP. GN Isolation refusé (cible D < C). Seuls CEE (sur ITE) et éco-PTZ tombent."
      },
      {
        titre: "Nancy G→B, intermédiaire — mix isolation + équipements (rénovation d'ampleur)",
        property: {
          city: "Nancy", code_insee: "54395", property_type: "maison",
          surface: 130, construction_year: 1955,
          dpe_class: "G", dpe_target: "B", income_bracket: "intermediaire",
          surface_ite: 110, surface_combles_perdus: 90,
          pac_air_eau: true, vmc_double_flux: true, audit_energetique: true,
          description: "ITE + isolation combles perdus + PAC air/eau + VMC double flux + audit"
        },
        attendus: %w[mpr_parcours_accompagne cee grand_nancy_renovation_globale eco_ptz],
        non_attendus: %w[mpr_par_geste grand_nancy_isolation],
        commentaire: "Saut 5 + 2 isolations + VMC → ampleur. dpe_target B → GN Reno Globale activée."
      },
      {
        titre: "Laxou F→D, modeste — UN seul geste (PAC air/eau)",
        property: {
          city: "Laxou", code_insee: "54304", property_type: "maison",
          surface: 105, construction_year: 1972,
          dpe_class: "F", dpe_target: "D", income_bracket: "modeste",
          pac_air_eau: true,
          description: "remplacement chauffage par PAC air/eau"
        },
        attendus: %w[mpr_par_geste cee eco_ptz],
        non_attendus: %w[grand_nancy_isolation],
        commentaire: "Geste isolé sans surface d'isolation → GN Isolation NON déclenchée (normal)."
      }
    ].freeze

    def run
      header_principal
      SCENARIOS.each_with_index { |scen, i| run_scenario(i + 1, scen) }
      pied_principal
    end

    private

    def header_principal
      puts ""
      puts "╔══════════════════════════════════════════════════════════════════════════╗"
      puts "║  FILET ANTI-RÉGRESSION — AidCalculatorService                            ║"
      puts "║  #{SCENARIOS.size} scénarios — exécution 100 % en mémoire, aucune API, aucun écrit DB  ║"
      puts "╚══════════════════════════════════════════════════════════════════════════╝"
    end

    def pied_principal
      puts ""
      puts "Fin. AidRule en DB au moment du test : #{AidRule.where(active: true).pluck(:slug).sort.inspect}"
      puts ""
    end

    def run_scenario(num, scen)
      property = Property.new(scen[:property])
      result   = AidCalculatorService.new(property).call

      puts ""
      puts "═" * 78
      puts "  Scénario #{num} — #{scen[:titre]}"
      puts "═" * 78
      puts ""
      afficher_contexte(property)
      puts ""
      afficher_subventions(result)
      afficher_financement(result)
      afficher_dvf(property)
      afficher_erreurs(result)
      afficher_anomalies(result, scen)
      puts ""
      puts "  Note : #{scen[:commentaire]}" if scen[:commentaire]
    end

    def afficher_contexte(p)
      saut = dpe_saut(p.dpe_class, p.dpe_target)
      puts "  Commune       : #{p.city} (INSEE #{p.code_insee})"
      puts "  Grand Nancy   : #{GrandNancy.include?(p.code_insee) ? 'OUI' : 'NON'}"
      puts "  DPE           : #{p.dpe_class} → #{p.dpe_target}  (saut #{saut} classe#{saut > 1 ? 's' : ''})"
      puts "  Tranche       : #{p.income_bracket}"
      puts "  Type / surface: #{p.property_type} · #{p.surface.to_i} m² · construit #{p.construction_year}"
      puts "  Travaux       : #{liste_travaux(p)}"
    end

    def afficher_subventions(result)
      puts "  Détail des subventions :"
      if result[:subventions].empty?
        puts "    (aucune)"
      else
        result[:subventions].each do |s|
          puts "    #{s[:slug].ljust(34)} #{format_euros(s[:amount]).rjust(12)}"
          puts "      └ #{s[:basis]}" if s[:basis].to_s.length.positive?
        end
        puts "    " + "─" * 46
        puts "    #{'TOTAL SUBVENTIONS'.ljust(34)} #{format_euros(result[:total_subventions]).rjust(12)}"
      end

      unless result[:aides_potentielles].empty?
        puts ""
        puts "  Aides potentielles (non activées dans ce scénario) :"
        result[:aides_potentielles].each do |s|
          puts "    #{s[:slug].ljust(34)} #{format_euros(s[:amount]).rjust(12)}  — #{s[:basis]}"
        end
      end
    end

    def afficher_financement(result)
      puts ""
      puts "  Financement (prêts, hors subventions) :"
      if result[:financement].empty?
        puts "    (aucun)"
      else
        result[:financement].each do |f|
          puts "    #{f[:slug].ljust(34)} #{format_euros(f[:amount]).rjust(12)}  — #{f[:basis]}"
        end
      end
    end

    def afficher_dvf(p)
      puts ""
      etat = p.code_insee == "54395" ? "disponible (Nancy)" : "indisponible (hors Nancy)"
      puts "  DVF           : #{etat}"
    end

    def afficher_erreurs(result)
      puts ""
      if result[:errors].empty?
        puts "  Erreurs       : aucune"
      else
        puts "  Erreurs       :"
        result[:errors].each { |e| puts "    · #{e}" }
      end
    end

    def afficher_anomalies(result, scen)
      slugs_emis = result[:subventions].map { |s| s[:slug] } + result[:financement].map { |f| f[:slug] }
      attendus   = Array(scen[:attendus])
      non_attend = Array(scen[:non_attendus])

      anomalies = []

      manquants = attendus - slugs_emis
      manquants.each { |slug| anomalies << "MANQUANT : #{slug} n'a pas été émis, attendu dans ce scénario." }

      a_zero = result[:subventions].select { |s| attendus.include?(s[:slug]) && s[:amount].to_i.zero? }
      a_zero.each { |s| anomalies << "À 0 € : #{s[:slug]} attendu non nul." }

      en_trop = slugs_emis - attendus - non_attend
      en_trop.each { |slug| anomalies << "INATTENDU : #{slug} émis mais ni attendu ni listé en non_attendu." }

      puts ""
      if anomalies.empty?
        puts "  Anomalies     : aucune ✓"
      else
        puts "  Anomalies (#{anomalies.size}) :"
        anomalies.each { |a| puts "    ⚠ #{a}" }
      end
    end

    def liste_travaux(p)
      parts = []
      parts << "ITE #{p.surface_ite.to_i} m²"                         if p.surface_ite.to_f.positive?
      parts << "ITI #{p.surface_iti.to_i} m²"                         if p.surface_iti.to_f.positive?
      parts << "sarking #{p.surface_sarking.to_i} m²"                 if p.surface_sarking.to_f.positive?
      parts << "combles perdus #{p.surface_combles_perdus.to_i} m²"   if p.surface_combles_perdus.to_f.positive?
      parts << "toiture-terrasse #{p.surface_toiture_terrasse.to_i} m²" if p.surface_toiture_terrasse.to_f.positive?
      parts << "plancher bas #{p.surface_plancher_bas.to_i} m²"       if p.surface_plancher_bas.to_f.positive?
      parts << "PAC air/eau"                                          if p.pac_air_eau
      parts << "PAC géothermique"                                     if p.pac_geothermique
      parts << "VMC double flux"                                      if p.vmc_double_flux
      parts << "chauffe-eau thermo"                                   if p.chauffe_eau_thermo
      parts << "audit énergétique"                                    if p.audit_energetique
      parts << "fenêtres ×#{p.nb_parois_vitrees}"                     if p.nb_parois_vitrees.to_i.positive?
      parts.empty? ? "(aucun travail détaillé)" : parts.join(" · ")
    end

    def dpe_saut(actuel, cible)
      ordre = %w[A B C D E F G]
      (ordre.index(actuel.to_s.upcase) || 0) - (ordre.index(cible.to_s.upcase) || 0)
    end

    def format_euros(n)
      "#{n.to_i.to_s.reverse.scan(/\d{1,3}/).join(' ').reverse} €"
    end
  end
end
