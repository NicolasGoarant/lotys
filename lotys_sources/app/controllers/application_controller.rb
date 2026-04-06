class ApplicationController < ActionController::Base
  layout :layout_by_resource

  def layout_by_resource
    devise_controller? ? "devise" : "application"
  end
  after_action :save_pending_property

  private

  def save_pending_property
    if user_signed_in? && session[:pending_property].present?
      current_user.properties.create(session.delete(:pending_property))
    end
  end
end
