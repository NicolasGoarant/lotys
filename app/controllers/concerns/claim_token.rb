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
# API :
#   - claim_tokens                       → jetons portés par le navigateur
#   - claimable_by_browser?(property)    → décide l'accès en lecture
#   - write_claim_cookie!(token)         → dépose le jeton à la création
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

  # Dépose le jeton dans un cookie signé (inviolable côté client). Appelé
  # par PropertiesController#create quand un visiteur anonyme crée son
  # premier bien. Le cookie expire dans 30 jours — aligné sur la durée
  # de vie attendue d'une orpheline avant que le job de nettoyage
  # (commit 5) ne la purge.
  #
  # Note : single-value (string), pas array. Si le visiteur crée un 2e
  # bien anonyme, le cookie est remplacé → l'accès à l'orpheline
  # précédente est perdu côté navigateur (elle reste en DB jusqu'au
  # nettoyage). Acceptable : aujourd'hui rien dans l'UI ne permet de
  # créer 2 brouillons consécutifs sans rattachement.
  def write_claim_cookie!(token)
    cookies.signed[CLAIM_COOKIE] = {
      value:    token,
      expires:  30.days.from_now,
      httponly: true,
      secure:   Rails.env.production?
    }
  end
end
