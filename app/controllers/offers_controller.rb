class OffersController < ApplicationController
  # index/new/create nécessitent d'être connecté
  before_action :authenticate_user!, except: [:new]

  # Seuls les prestataires peuvent créer/voir le formulaire d'offre.
  # Les propriétaires n'ont rien à faire dans new/create.
  before_action :require_prestataire, only: [:new, :create]

  # Pour new et create : on charge @property via la branche "published",
  # comme l'ancien code, mais on refuse si le prestataire est en fait aussi
  # le propriétaire du bien (cas marginal mais à bloquer).
  before_action :set_property_for_offer, only: [:new, :create]

  # index : un propriétaire voit les offres reçues sur SES biens,
  # un prestataire voit LES OFFRES QU'IL A ÉMISES.
  # Actuellement seul le cas propriétaire était géré ; on complète.
  def index
    if current_user.proprietaire?
      @offers = Offer.joins(:property)
                     .where(properties: { user_id: current_user.id })
                     .includes(:property, :user)
                     .order(created_at: :desc)
    elsif current_user.prestataire?
      @offers = current_user.offers
                            .includes(:property)
                            .order(created_at: :desc)
    else
      @offers = Offer.none
    end

    @properties = Property.published
                          .includes(:valuation, :device_simulation, :offers)
                          .order(created_at: :desc)
  end

  def new
    # @property et vérifs déjà faites par les before_actions
    @offer = @property.offers.build
  end

  def create
    @offer = @property.offers.build(offer_params)
    @offer.user = current_user
    @offer.status = :pending
    @offer.expires_at = 30.days.from_now

    if @offer.save
      OfferMailer.new_offer(@offer).deliver_later
      redirect_to offers_path, notice: "Votre offre a été transmise au propriétaire."
    else
      render :new, status: :unprocessable_entity
    end
  end

  # Un propriétaire ne peut modifier le status QUE des offres reçues sur SES biens.
  # On whiteliste les status acceptés pour ne pas casser l'enum avec un param libre.
  ALLOWED_STATUSES = %w[accepted rejected].freeze

  def update
    @offer = Offer.joins(:property)
                  .where(properties: { user_id: current_user.id })
                  .find_by(id: params[:id])

    unless @offer
      redirect_to offers_path, alert: "Offre introuvable ou non autorisée."
      return
    end

    new_status = params[:status].to_s
    unless ALLOWED_STATUSES.include?(new_status)
      redirect_to offers_path, alert: "Statut invalide."
      return
    end

    @offer.update(status: new_status)
    redirect_to offers_path, notice: "Offre mise à jour."
  end

  private

  # Vérifie que l'utilisateur connecté est prestataire. Bloque les propriétaires
  # qui tenteraient de faire une offre sur un bien (y compris le leur).
  def require_prestataire
    # Si non connecté, on laisse passer la tentative à authenticate_user! qui
    # redirigera vers la page de connexion. Ici on se concentre sur les connectés.
    return unless user_signed_in?
    return if current_user.prestataire?

    redirect_to root_path, alert: "Seuls les prestataires peuvent faire une offre."
  end

  # Charge @property parmi les biens publiés puis bloque toute tentative
  # d'auto-proposition — défense en profondeur. Deux critères cumulatifs
  # d'exclusion (l'un OU l'autre suffit) :
  #   - le user connecté possède le bien (propriétaire au sens compte),
  #   - le navigateur porte le claim_token de ce bien (parcours anonyme).
  # Le second critère couvre le cas rare où le porteur du bien (au sens
  # claim_token) crée un compte prestataire et tenterait de s'auto-offrir
  # une proposition avant que le rattachement ait vidé son cookie.
  def set_property_for_offer
    @property = Property.published.find_by(id: params[:property_id])

    unless @property
      redirect_to root_path, alert: "Ce bien n'est plus disponible."
      return
    end

    if porteur_du_bien?(@property)
      redirect_to root_path, alert: "Vous ne pouvez pas faire une offre sur votre propre bien."
    end
  end

  # Vrai si le visiteur courant est le porteur du bien, au sens large :
  # propriétaire connecté OU navigateur avec le claim_token du bien.
  def porteur_du_bien?(property)
    (user_signed_in? && property.user_id == current_user.id) ||
      (property.claim_token.present? && claim_tokens.include?(property.claim_token))
  end

  def offer_params
    params.require(:offer).permit(:offer_type, :amount, :description)
  end
end
