# Table de normalisation libellé libre → énergie typée du moteur 3CL.
#
# SOURCE DE VÉRITÉ UNIQUE. Tout consommateur DOIT lire cette table :
#  - PropertyDataExtractorService (capture depuis le JSON heating_system de Claude)
#  - tmp/validate_dpe_engine.rb (validation non-régression sur biens réels)
#  - futur formulaire de saisie utilisateur (normalisation d'un texte libre)
#  - futur prompt d'extraction structurée du DPE PDF
#
# Pas de copie locale, jamais. Le piège DPE_IMPACT (constante Ruby + clone
# JS divergent) prouve que deux copies finissent par diverger.
#
# Ordre de la table = priorité de matching : équipement spécifique avant
# énergie générique. « PAC électrique » doit matcher :pac (pas :electricite,
# car le moteur 3CL traite la PAC via COP, ≠ convecteur ×1,9). « Poêle à
# bois » match :bois via /poêle/ avant que /bois/ ne s'applique seul.
#
# Couvre les 5 énergies de DpeEngineService::RG + :inconnue (absence honnête).
class HeatingEnergyNormalizer
  MAPPING = [
    [:pac,         /pompe à chaleur|pac air|pac eau|pac géoth|pac aérot/i],
    [:bois,        /granulé|granules|bûches|buches|poêle|poele|insert|chaudière bois|chaudiere bois/i],
    [:fioul,       /fioul|mazout/i],
    [:gaz,         /\bgaz\b|chaudière gaz|chaudiere gaz/i],
    [:electricite, /électr|electr|convecteur|effet joule|grille[- ]pain|panneau radiant/i]
  ].freeze

  # Retourne le symbole d'énergie correspondant au libellé, ou :inconnue
  # si rien ne matche / libellé vide. Ne lève jamais.
  def self.call(libelle)
    return :inconnue if libelle.nil? || libelle.to_s.strip.empty?
    MAPPING.each { |sym, regex| return sym if libelle.match?(regex) }
    :inconnue
  end
end
