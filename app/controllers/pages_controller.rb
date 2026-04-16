class PagesController < ApplicationController
  def home
    @published_properties = Property.where(status: [:analyzed, :published])
                                    .where.not(lat: nil, lng: nil)
                                    .select(:id, :address, :city, :property_type,
                                            :surface, :dpe_class, :lat, :lng)
                                    .includes(:offers, :valuation)
  end

  def how_it_works
  end

  def about
  end

  def mentions_legales
  end

  def confidentialite
  end

  def contact
  end
end
