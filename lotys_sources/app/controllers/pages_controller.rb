class PagesController < ApplicationController
  def home
    @published_properties = Property.where(status: [:analyzed, :published])
                                    .where.not(lat: nil, lng: nil)
                                    .select(:id, :address, :city, :property_type,
                                            :surface, :dpe_class, :lat, :lng)
  end

  def how_it_works
  end

  def about
  end
end
