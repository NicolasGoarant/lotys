# app/mailers/offer_mailer.rb
class OfferMailer < ApplicationMailer
  default from: "Lauze <noreply@lauze.fr>"

  def new_offer(offer)
    @offer    = offer
    @property = offer.property
    @owner    = @property.user

    mail(
      to:      @owner.email,
      subject: "💼 Nouvelle proposition reçue pour #{@property.address}"
    )
  end
end
