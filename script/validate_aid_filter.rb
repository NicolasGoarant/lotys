# script/validate_aid_filter.rb
#
# Valide que AidCalculatorService filtre bien les aides selon travaux_actifs.
# Usage :
#   bin/rails runner script/validate_aid_filter.rb
#
# Stratégie :
#   1. Prend le premier bien Grand Nancy avec equipements_selection non vide
#   2. Calcule les aides SANS filtre (comportement historique)
#   3. Calcule les aides AVEC filtre = [] (aucune case cochée)
#   4. Calcule les aides AVEC filtre = travaux_actifs réel du bien
#   5. Affiche les 3 résultats côte à côte pour comparaison visuelle
#
# Attendu :
#   - Sans filtre : montant maximal (toutes les aides que permet la propriété)
#   - Filtre [] : montant minimal (aucun équipement ni surface → MPR Ampleur
#     peut rester si éligible car calculé sur un budget global)
#   - Filtre travaux_actifs : entre les deux, cohérent avec les cases cochées

def format_eur(n) = "#{n.to_i.to_s.reverse.scan(/\d{1,3}/).join(' ').reverse} €"

def dump_result(label, result)
  puts "─" * 70
  puts label
  puts "─" * 70
  puts "  Total subventions : #{format_eur(result[:total_subventions])}"
  result[:subventions].each do |s|
    amount  = format_eur(s[:amount])
    type    = s[:type] || s[:slug]
    puts "    • #{type.to_s.ljust(40)} #{amount.rjust(14)}"
  end
  if result[:financement].any?
    puts "  Financement (prêts) :"
    result[:financement].each do |f|
      puts "    • #{(f[:type] || f[:name]).to_s.ljust(40)} #{format_eur(f[:amount]).rjust(14)}"
    end
  end
  if result[:errors].any?
    puts "  Erreurs :"
    result[:errors].each { |e| puts "    ! #{e}" }
  end
end

# 1. Cible un bien qui a des équipements et des surfaces
candidate = Property.where.not(equipements_selection: {})
                    .where.not(travaux_selection: {})
                    .find { |p| p.travaux_actifs.any? && p.equipements_selection.values.any? }

if candidate.nil?
  puts "Aucun bien en base avec equipements_selection ET travaux_selection renseignés."
  puts "Crée un bien test ou relance PropertyAnalysisJob sur un bien existant."
  exit 1
end

puts "Bien analysé : ##{candidate.id} — #{candidate.address}"
puts "  DPE : #{candidate.dpe_class} → #{candidate.dpe_target}"
puts "  Revenus : #{candidate.income_bracket}"
puts "  equipements_selection (clés non nulles) :"
candidate.equipements_selection.each do |k, v|
  next if v.nil? || v == false || v == 0
  puts "    #{k.ljust(30)} = #{v}"
end
puts "  travaux_actifs : #{candidate.travaux_actifs.inspect}"
puts

# 2. Calcul sans filtre (comportement historique)
r1 = AidCalculatorService.new(candidate).call
dump_result("SANS FILTRE (comportement historique)", r1)

# 3. Calcul avec filtre vide : attend 0 sur MPR Par geste / CEE équipement
r2 = AidCalculatorService.new(candidate, travaux_actifs: []).call
dump_result("AVEC FILTRE = [] (toutes cases décochées)", r2)

# 4. Calcul avec travaux_actifs réel
r3 = AidCalculatorService.new(candidate, travaux_actifs: candidate.travaux_actifs).call
dump_result("AVEC FILTRE = travaux_actifs réels (#{candidate.travaux_actifs.inspect})", r3)

puts "─" * 70
puts "Vérifications"
puts "─" * 70

# Assertions
checks = []

# (a) filtre [] = filtre strict doit donner un montant ≤ sans filtre.
# Comme ce bien ne permet pas MPR Ampleur (saut DPE < 2), on s'attend à ce
# que filtre=[] donne MPR Par geste = 0, CEE = 0, donc total < sans filtre.
if r2[:total_subventions] < r1[:total_subventions]
  checks << "✅ filtre [] < sans filtre (#{format_eur(r2[:total_subventions])} < #{format_eur(r1[:total_subventions])})"
elsif r2[:total_subventions] == r1[:total_subventions]
  checks << "⚠️  filtre [] == sans filtre : vérifier que MPR Ampleur explique le montant (saut DPE ≥ 2 ?) ou signe d'un bug"
else
  checks << "❌ filtre [] > sans filtre : incohérent"
end

# (b) filtre travaux_actifs réels : résultat doit être entre les deux extrêmes.
if r3[:total_subventions] <= r1[:total_subventions] && r3[:total_subventions] >= r2[:total_subventions]
  checks << "✅ filtre travaux_actifs ∈ [#{format_eur(r2[:total_subventions])}, #{format_eur(r1[:total_subventions])}]"
else
  checks << "❌ filtre travaux_actifs hors bornes : #{format_eur(r3[:total_subventions])} n'est pas entre #{format_eur(r2[:total_subventions])} et #{format_eur(r1[:total_subventions])}"
end

# (c) Si des équipements chauffage sont en base mais chauffage pas dans travaux_actifs,
# alors r3 < r1.
has_chauffage_equip = %w[pac_air_eau pac_geothermique poele_buches poele_granules insert_foyer]
                      .any? { |k| candidate.send(k) == true }
chauffage_coche     = candidate.travaux_actifs.include?("chauffage")

if has_chauffage_equip && !chauffage_coche
  if r3[:total_subventions] < r1[:total_subventions]
    checks << "✅ équipement chauffage ignoré car case chauffage décochée (r3 < r1)"
  else
    checks << "❌ équipement chauffage en BDD mais case décochée, pourtant r3 == r1 — le filtre ne fonctionne pas"
  end
end

# (d) Inverse : si nb_parois_vitrees > 0 mais menuiseries pas dans travaux_actifs,
# alors r3 < r1 (effet sur MPR Par geste + CEE).
if candidate.nb_parois_vitrees.to_i > 0 && !candidate.travaux_actifs.include?("menuiseries")
  if r3[:total_subventions] < r1[:total_subventions]
    checks << "✅ nb_parois_vitrees=#{candidate.nb_parois_vitrees} ignoré car case menuiseries décochée (r3 < r1)"
  else
    checks << "❌ nb_parois_vitrees en BDD mais menuiseries décochée, pourtant r3 == r1 — le filtre ne fonctionne pas"
  end
end

puts checks.join("\n")
puts

exit(checks.none? { |c| c.start_with?("❌") } ? 0 : 2)
