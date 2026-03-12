class OffersController < ApplicationController
  before_action :authenticate_user!, except: [:index]

  def index
    if user_signed_in? && current_user.proprietaire?
      @offers = Offer.joins(:property)
                     .where(properties: { user_id: current_user.id })
                     .includes(:property, :user)
                     .order(created_at: :desc)
    end
    @properties = Property.published
                           .includes(:valuation, :device_simulation, :offers)
                           .order(created_at: :desc)
  end

  def create
    @property = Property.published.find(params[:property_id])
    @offer = @property.offers.build(offer_params)
    @offer.user = current_user
    @offer.status = :pending
    @offer.expires_at = 30.days.from_now
    if @offer.save
      redirect_to offers_path, notice: "Votre offre a été transmise au propriétaire."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    @offer = Offer.joins(:property)
                  .where(properties: { user_id: current_user.id })
                  .find(params[:id])
    @offer.update(status: params[:status])
    redirect_to offers_path, notice: "Offre mise à jour."
  end

  private

  def offer_params
    params.require(:offer).permit(:offer_type, :amount, :description)
  end
end
