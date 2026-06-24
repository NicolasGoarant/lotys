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
#   - claim_orphans!(user)               → rattache jusqu'à la limite,
#                                          retourne { claimed:, left_behind: },
#                                          ne perd jamais une orpheline
#   - delete_claim_cookie!               → efface le cookie (no-op si vide)
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
  # premier bien. Le cookie expire dans 30 jours — fenêtre laissée à
  # l'utilisateur entre création anonyme et signup/sign-in confirmé.
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

  # Efface le cookie de revendication. Appelé après une tentative de claim,
  # qu'elle ait réussi ou non — le navigateur n'a plus de raison de garder
  # un jeton (soit le bien est rattaché, soit il est introuvable, soit
  # la limite a empêché le claim et l'utilisateur devra refaire un
  # parcours propre).
  def delete_claim_cookie!
    cookies.delete(CLAIM_COOKIE)
  end

  # Limite alignée avec PropertiesController#create — un User ne peut pas
  # détenir plus de PROPERTY_LIMIT biens. Le claim respecte ce plafond et
  # met le reste en attente (cf. left_behind).
  PROPERTY_LIMIT = 3

  # Rattache les Property orphelines dont les jetons sont portés par ce
  # navigateur au User donné. Tolérant aux jetons sans property en DB
  # (purgée, expirée, déjà rattachée par un autre device).
  #
  # Politique « zéro perte » (commit 5/5) :
  #   - rattache JUSQU'À la limite de PROPERTY_LIMIT biens par user,
  #   - les orphelines en surplus restent INTACTES en DB (user_id: nil,
  #     claim_token préservé) → encore revendicables au prochain sign-in,
  #   - le cookie est RÉÉCRIT avec UNIQUEMENT les jetons des left_behind
  #     (ou supprimé si tout a été claim) pour que le navigateur puisse
  #     reprendre le claim après libération de place.
  #
  # Garde-fous historiques préservés :
  #   - where(user_id: nil) → ne vole JAMAIS un bien déjà possédé.
  #   - rescue StandardError au niveau du callback appelant
  #     (ApplicationController) → ne casse JAMAIS le flow Devise.
  #
  # Retourne un Hash structuré :
  #   { claimed: [Property, ...], left_behind: [Property, ...] }
  def claim_orphans!(user)
    empty_result = { claimed: [], left_behind: [] }
    return empty_result if user.nil?
    return empty_result if claim_tokens.empty?

    claimed     = []
    left_behind = []

    claim_tokens.each do |token|
      orphan = Property.where(user_id: nil, claim_token: token).first
      next unless orphan   # jeton dans le cookie sans property → ignore

      # Le compteur est réévalué à chaque tour : un claim réussi monte la
      # jauge et peut faire basculer les suivants en left_behind.
      if user.properties.count >= PROPERTY_LIMIT
        left_behind << orphan
        Rails.logger.info("[ClaimToken] user##{user.id} a atteint #{PROPERTY_LIMIT} biens — orphan ##{orphan.id} mis en attente (token préservé)")
        next
      end

      # Clear du claim_token au moment du rattachement : le bien devient
      # un bien possédé classique, plus une orpheline. L'invariant
      # #rattachable reste satisfait par user_id présent.
      if orphan.update(user_id: user.id, claim_token: nil)
        claimed << orphan
        Rails.logger.info("[ClaimToken] orphan ##{orphan.id} rattaché à user##{user.id}")
      else
        # Échec d'update (validation cassée) : on traite l'orpheline comme
        # left_behind pour ne pas la perdre côté cookie.
        left_behind << orphan
        Rails.logger.error("[ClaimToken] rattachement orphan ##{orphan.id} échoué : #{orphan.errors.full_messages.join(', ')}")
      end
    end

    rewrite_or_delete_cookie!(left_behind)
    { claimed: claimed, left_behind: left_behind }
  end

  private

  # Politique cookie post-claim :
  #   - left_behind vide   → rien à reprendre, on supprime le cookie.
  #   - left_behind non vide → on réécrit le cookie signé avec EXACTEMENT
  #     les jetons des orphelines restées en attente. Les jetons des
  #     orphelines claimed disparaissent (leur claim_token a été nullifié
  #     en DB, ils ne servent plus à rien côté navigateur).
  # Single-string si une seule orpheline restante (cohérent avec
  # write_claim_cookie! qui pose une string), tableau au-delà — le
  # lecteur claim_tokens accepte les deux via Array(raw).
  def rewrite_or_delete_cookie!(left_behind)
    if left_behind.empty?
      delete_claim_cookie!
      return
    end

    remaining_tokens = left_behind.map(&:claim_token)
    value            = remaining_tokens.size == 1 ? remaining_tokens.first : remaining_tokens

    cookies.signed[CLAIM_COOKIE] = {
      value:    value,
      expires:  30.days.from_now,
      httponly: true,
      secure:   Rails.env.production?
    }
  end
end
