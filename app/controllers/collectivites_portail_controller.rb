# Feature portail collectivité (niveau 1 B2G) — page publique à
# GET /collectivites/:slug. Affiche le branding EPCI et propose le
# parcours d'analyse pré-paramétré (link vers /properties/new avec
# le slug en param — cf. C6 pour le rattachement du bien créé).
#
# Anonyme : pas d'authentification requise. Le portail est fait pour
# être partagé publiquement (site EPCI, réseau sociaux, courrier).
class CollectivitesPortailController < ApplicationController
  before_action :set_collectivite, only: [:show]

  def show
    # Compteur "biens analysés sur votre territoire" — donnée RÉELLE
    # (aucun chiffre inventé). Statuts analyzed + published couvrent
    # les biens qui ont été traités par le pipeline (les brouillons
    # sans code_insee ne comptent pas), publiés ou non — un
    # compteur crédible en rendez-vous commercial doit refléter
    # l'usage effectif, pas seulement la vitrine publique.
    @count_biens = Property.where(
      code_insee: @collectivite.insee_codes,
      status:     [Property.statuses[:analyzed], Property.statuses[:published]]
    ).count
  end

  private

  def set_collectivite
    @collectivite = Collectivite.active.find_by(slug: params[:slug])
    return if @collectivite

    # Portail inconnu OU désactivé : on retombe sur la page marketing
    # générique /collectivites avec un flash. Pas d'exposition
    # d'information (pas de distinction "inconnu" vs "désactivé")
    # pour ne pas leaker la présence de portails éteints.
    redirect_to collectivites_path,
                alert: "Ce portail collectivité n'existe pas ou n'est plus disponible."
  end
end
