#!/usr/bin/env ruby
# script/test_aid_calculator_i4ce.rb
#
# Test de régression d'AidCalculatorService face à un référentiel
# externe : la note de l'Institut de l'économie pour le climat (I4CE)
# du 7 mai 2026 sur l'accès des ménages à la transition écologique.
#
# Lancement :
#   bin/rails runner script/test_aid_calculator_i4ce.rb
#
# Ce script ne fait PAS échouer le build : c'est un outil de diagnostic
# qui imprime un comparatif. À toi de lire l'écart et de décider si
# le service Lauze est calibré, ou s'il dérive par rapport à la
# référence externe.
#
# Cas type I4CE 2026 :
#   - Ménage rural, classe moyenne inférieure (3 900 €/mois, 2 enfants)
#   - Maison individuelle chauffée au fioul, DPE G
#   - Rénovation globale (≈ 65 000 € de travaux)
#   - Aides 2026 : 24 000 € (vs 42 713 € en 2025)
#   - Reste à charge 2026 : 40 866 € (vs 21 662 € en 2025)
#   - Source : note I4CE, Observatoire des conditions d'accès à la
#     transition écologique, publiée le 7 mai 2026.
#
# Mapping cas I4CE → modèle Property Lauze :
#   - income_bracket "modeste" (revenu fiscal ≈ 46 800 €/an)
#   - dpe_class "G", dpe_target "C" (saut 4 classes → plafond MPR 40 000 € HT)
#   - construction_year 1970 (≥ 15 ans, éligible MPR)
#   - city "Verdun" / zipcode "55100" (rural, hors Grand Nancy)
#   - 100 m² (maison rurale typique)
#   - Travaux : isolation toiture + murs + chauffage (PAC) + VMC, fioul déposé
# ============================================================================

# ── Référence externe I4CE 2026 ────────────────────────────────────────────
REFERENCE_I4CE = {
  source:           "I4CE, Observatoire des conditions d'accès à la transition écologique, note du 7 mai 2026",
  cout_travaux_ttc: 64_866,
  total_aides:      24_000,
  reste_a_charge:   40_866,
  mensualite_pret:  176,    # éco-PTZ + prêt complémentaire combinés
  facture_apres:    67      # €/mois post-travaux
}.freeze

# Tolérance acceptable pour le diagnostic. Au-delà de ±15 %, c'est qu'il
# y a un vrai écart à creuser (paramétrage MPR, prise en compte du saut
# de classes, plafonds non actualisés, etc.).
TOLERANCE_PCT = 15

# ── Helpers d'affichage ────────────────────────────────────────────────────
def section(title)
  puts
  puts "━" * 78
  puts "  #{title}"
  puts "━" * 78
end

def kv(label, value, indent: 2)
  puts "#{' ' * indent}#{label.to_s.ljust(38)} #{value}"
end

def euro(n)
  return "—" if n.nil?
  "#{n.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1 ').reverse} €"
end

def diff_pct(actual, ref)
  return nil if ref.zero?
  ((actual.to_f - ref) / ref * 100).round(1)
end

def verdict(pct)
  return "—" if pct.nil?
  abs = pct.abs
  if abs <= TOLERANCE_PCT
    "✓ dans la tolérance (±#{TOLERANCE_PCT} %)"
  else
    "✗ écart hors tolérance (#{pct >= 0 ? '+' : ''}#{pct} % vs réf.)"
  end
end

# ── Setup de la propriété de test ──────────────────────────────────────────
section "Setup — création d'une Property cas I4CE"

# On essaie d'abord le compte test connu, sinon on prend le premier user.
user = User.find_by(email: "nicolas@lotys.fr") ||
       User.find_by(email: "nicolas@lauze.fr") ||
       User.first

unless user
  warn "Aucun User en base. Crée au moins un compte avant de lancer ce script."
  exit 1
end

kv "User retenu", user.email

# La propriété est créée puis détruite à la fin (block ensure).
# city/zipcode hors Grand Nancy pour neutraliser les aides locales et
# isoler la mesure des aides nationales (MPR + CEE), seul périmètre
# directement comparable à la note I4CE.
property = Property.new(
  user:              user,
  property_type:     "maison",
  address:           "Cas type I4CE — non géolocalisable",
  city:              "Verdun",
  zipcode:           "55100",
  surface:           100,
  nb_rooms:          5,
  construction_year: 1970,
  dpe_class:         "G",
  dpe_target:        "C",
  income_bracket:    "modeste",
  status:            :draft
)

# Macro-postes cochés : isolation toiture + murs + chauffage + VMC.
# Cohérent avec une rénovation globale fioul → PAC + isolation enveloppe.
property.travaux_selection = {
  "isolation_toiture"      => true,
  "isolation_murs"         => true,
  "isolation_plancher_bas" => false,
  "chauffage"              => true,
  "chauffe_eau"            => false,
  "vmc"                    => true,
  "menuiseries"            => false
}

# Équipements détaillés (pour MPR Par geste fallback, et CEE).
property.equipements_selection = {
  "pac_air_eau"      => true,
  "vmc_double_flux"  => true,
  "depose_fioul"     => true
}

unless property.save
  warn "Échec de validation Property : #{property.errors.full_messages.join(' / ')}"
  exit 1
end

kv "Property #id",          property.id
kv "Localisation",          "#{property.city} (#{property.zipcode}) — hors Grand Nancy"
kv "DPE actuel → cible",    "#{property.dpe_class} → #{property.dpe_target} (saut 4 classes)"
kv "Tranche revenus",       property.income_bracket
kv "Surface / construction","#{property.surface} m² / #{property.construction_year}"
kv "Macro-postes cochés",   property.travaux_actifs.join(", ")

begin
  # ── Calcul ────────────────────────────────────────────────────────────────
  section "Appel AidCalculatorService"

  result = AidCalculatorService.new(property, travaux_actifs: property.travaux_actifs).call

  total_subv      = result[:total_subventions].to_i
  total_financing = result[:financement].sum { |f| f[:amount].to_i }

  puts
  puts "  Subventions retournées :"
  if result[:subventions].any?
    result[:subventions].each do |s|
      puts "    • #{s[:name].to_s.ljust(50)} #{euro(s[:amount])}"
    end
  else
    puts "    (aucune)"
  end

  puts
  puts "  Financement (prêts) :"
  if result[:financement].any?
    result[:financement].each do |f|
      puts "    • #{f[:name].to_s.ljust(50)} #{euro(f[:amount])}"
    end
  else
    puts "    (aucun)"
  end

  if result[:errors].any?
    puts
    puts "  Notes / écrêtements :"
    result[:errors].each { |e| puts "    ⚠ #{e}" }
  end

  # ── Comparaison à la référence I4CE ───────────────────────────────────────
  section "Comparatif vs référence I4CE (note du 7 mai 2026)"

  pct = diff_pct(total_subv, REFERENCE_I4CE[:total_aides])

  puts
  kv "Référence I4CE — total aides 2026",    euro(REFERENCE_I4CE[:total_aides])
  kv "Lauze — total subventions calculées",  euro(total_subv)
  kv "Écart",                                pct.nil? ? "—" : "#{pct >= 0 ? '+' : ''}#{pct} %"
  kv "Verdict",                              verdict(pct)

  puts
  puts "  Détail référence I4CE pour mémoire :"
  kv "Coût total travaux TTC",     euro(REFERENCE_I4CE[:cout_travaux_ttc]), indent: 4
  kv "Reste à charge ménage",      euro(REFERENCE_I4CE[:reste_a_charge]),   indent: 4
  kv "Mensualité prêts combinés",  "#{REFERENCE_I4CE[:mensualite_pret]} €/mois",  indent: 4
  kv "Facture énergie post-trav.", "#{REFERENCE_I4CE[:facture_apres]} €/mois",    indent: 4

  # ── Pistes de lecture en cas d'écart ──────────────────────────────────────
  if pct && pct.abs > TOLERANCE_PCT
    section "Pistes en cas d'écart hors tolérance"
    puts <<~TEXT
        L'écart peut venir de plusieurs sources connues :

        1. Plafond MPR. L'article I4CE mentionne que l'ANAH a abaissé son
           plafond et supprimé le bonus sortie de passoire en 2026. Vérifier
           que MPR_PLAFOND_TRAVAUX_HT[4] reflète bien la valeur 2026 et non
           celle de 2025.

        2. Périmètre des aides comptées. I4CE intègre vraisemblablement
           MPR + CEE. Lauze ajoute les aides locales (Grand Nancy ici
           neutralisées via city = Verdun). Si l'écart persiste, comparer
           uniquement la ligne MPR.

        3. Montant des travaux pris en compte. Le service utilise
           estimated_cost_ht, qui dépend des équipements et surfaces. Le
           cas I4CE chiffre 64 866 € TTC ; le service peut sortir un
           montant différent selon les surfaces non renseignées ici.

        4. Saut de classes DPE. Vérifier que dpe_saut("G", "C") = 4 et que
           le plafond appliqué est bien 40 000 € HT.
      TEXT
  end

ensure
  # ── Cleanup ──────────────────────────────────────────────────────────────
  section "Cleanup"
  if property.persisted?
    property.destroy
    kv "Property ##{property.id}", "détruite"
  end
end

puts
puts "━" * 78
puts "  Source de référence : #{REFERENCE_I4CE[:source]}"
puts "━" * 78
puts
