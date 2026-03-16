Rails.application.routes.draw do
  get "pages/home"
  devise_for :users

  root "pages#home"
  get "/a-propos", to: "pages#about", as: :about

  resources :properties do
    member do
      post :analyze
      post :publish
      patch :update_dpe_target
    end
    resources :documents, only: [:new, :create, :destroy]
    resources :offers, only: [:new, :create]
  end

  resources :offers, only: [:index, :update]
  namespace :admin do
    resources :local_aid_schemes do
      member { post :toggle_active }
    end
  end

end
