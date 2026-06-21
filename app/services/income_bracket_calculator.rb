class IncomeBracketCalculator
  # Plafonds RFR 2026 hors Île-de-France (source : fiches ALEC Nancy Grands
  # Territoires, mise à jour mai 2026). Bornes SUPÉRIEURES incluses de chaque
  # tranche ; "superieur" = RFR strictement au-dessus du plafond intermédiaire.
  # Au-delà de 5 personnes : valeur "5 personnes" + (n-5) × incrément.
  PLAFONDS_2026 = {
    1 => { tres_modeste: 17_363, modeste: 22_259, intermediaire: 31_185 },
    2 => { tres_modeste: 25_393, modeste: 32_553, intermediaire: 45_842 },
    3 => { tres_modeste: 30_540, modeste: 39_148, intermediaire: 55_196 },
    4 => { tres_modeste: 35_676, modeste: 45_735, intermediaire: 64_550 },
    5 => { tres_modeste: 40_835, modeste: 52_348, intermediaire: 73_907 }
  }.freeze

  INCREMENT_PAR_PERSONNE = {
    tres_modeste: 5_151, modeste: 6_598, intermediaire: 9_357
  }.freeze

  # "tres_modeste" | "modeste" | "intermediaire" | "superieur" | nil
  def self.bracket_for(rfr:, household_size:)
    rfr  = rfr.to_i
    size = household_size.to_i
    return nil if rfr <= 0 || size <= 0

    seuils = plafonds_for(size)
    if    rfr <= seuils[:tres_modeste]  then "tres_modeste"
    elsif rfr <= seuils[:modeste]       then "modeste"
    elsif rfr <= seuils[:intermediaire] then "intermediaire"
    else                                     "superieur"
    end
  end

  # Plafonds (très modeste / modeste / intermédiaire) pour une taille de ménage,
  # extrapolés au-delà de 5 personnes. Réutilisable pour les libellés de la vue.
  def self.plafonds_for(household_size)
    size = [household_size.to_i, 1].max
    return PLAFONDS_2026[size] if PLAFONDS_2026.key?(size)

    extra = size - 5
    PLAFONDS_2026[5].each_with_object({}) do |(k, v), h|
      h[k] = v + extra * INCREMENT_PAR_PERSONNE[k]
    end
  end
end
