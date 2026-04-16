Rails.application.routes.draw do
  get "pages/home"
  devise_for :users

  root "pages#home"
  get "/a-propos", to: "pages#about", as: :about
  get "/borne-electrique",    to: "pages#borne_electrique",   as: :borne_electrique
  get "/panneaux-solaires",   to: "pages#panneaux_solaires",  as: :panneaux_solaires
  get "/location-meublee",    to: "pages#location_meublee",   as: :location_meublee
  get "/amenagement-combles", to: "pages#amenagement_combles", as: :amenagement_combles
  get "/espace-exterieur",    to: "pages#espace_exterieur",   as: :espace_exterieur
  get "/box-stockage",        to: "pages#box_stockage",        as: :box_stockage

  get "/mentions-legales",    to: "pages#mentions_legales",   as: :mentions_legales
  get "/confidentialite",     to: "pages#confidentialite",    as: :confidentialite
  get "/contact",             to: "pages#contact",            as: :contact

  resources :properties do
    member do
      post :analyze
      post :publish
      post :unpublish
      get  :preview
      patch :update_dpe_target
      patch :update_income_bracket
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
