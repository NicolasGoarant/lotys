# Lecture/écriture du jeton de revendication d'une Property orpheline.
#
# Mécanique : le visiteur anonyme crée un bien sans compte → une Property
# est créée avec user_id: nil et un claim_token aléatoire. Ce jeton est
# aussi déposé dans un cookie SIGNÉ côté navigateur. À chaque accès, on
# vérifie que le cookie présente bien le jeton de l'orpheline demandée.
#
# Cookie signé (cookies.signed) :
#   - cryptographiquement vérifié par Rails (clé secrète serveur),
#   - lisible côté client mais NON modifiable sans la clé,
#   - protège contre l'usurpation : un visiteur ne peut pas se fabriquer
#     un jeton à la main pour accéder à l'orpheline d'un autre navigateur.
#
# Ce concern fournit UNIQUEMENT la lecture pour ce commit. L'écriture
# (pose du cookie au moment de la création anonyme) arrivera au commit 3.
module ClaimToken
  extend ActiveSupport::Concern

  CLAIM_COOKIE = :lauze_claim_token

  # Liste des jetons que ce navigateur peut revendiquer. Tableau pour
  # tolérer plusieurs brouillons simultanés un jour ; aujourd'hui un seul
  # élément maximum (le dernier bien créé en anonyme).
  def claim_tokens
    raw = cookies.signed[CLAIM_COOKIE]
    raw.present? ? Array(raw) : []
  end

  # Vrai si l'orpheline donnée porte un jeton que CE navigateur peut lire.
  # Trois conditions cumulatives :
  #   - la property est orpheline (user_id nil) — sinon c'est un bien
  #     possédé, l'autorisation passe par current_user, pas par ce chemin.
  #   - elle a un claim_token (sinon elle est invalide d'après l'invariant
  #     #rattachable, mais la défense en profondeur ne coûte rien).
  #   - le cookie du navigateur contient ce même jeton.
  def claimable_by_browser?(property)
    property.user_id.nil? &&
      property.claim_token.present? &&
      claim_tokens.include?(property.claim_token)
  end
end
