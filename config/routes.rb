Rails.application.routes.draw do
  get "pages/home"
  devise_for :users, controllers: { confirmations: "users/confirmations" }

  root "pages#home"
  get "/a-propos", to: "pages#about", as: :about
  get "/borne-electrique",    to: "pages#borne_electrique",   as: :borne_electrique
  get "/panneaux-solaires",   to: "pages#panneaux_solaires",  as: :panneaux_solaires
  get "/location-meublee",    to: "pages#location_meublee",   as: :location_meublee
  get "/amenagement-combles", to: "pages#amenagement_combles", as: :amenagement_combles
  get "/espace-exterieur",    to: "pages#espace_exterieur",   as: :espace_exterieur
  get "/box-stockage",        to: "pages#box_stockage",        as: :box_stockage

  # Pages dédiées par public cible (hub personas depuis la home)
  get "/proprietaires",       to: "pages#proprietaires",       as: :proprietaires
  get "/artisans",            to: "pages#artisans",            as: :artisans
  get "/collectivites",       to: "pages#collectivites",       as: :collectivites
  # Portail par collectivité (feature B2G niveau 1). :slug est validé
  # côté modèle (kebab-case) ; find_by(slug:) côté controller. Cette
  # route est POSTÉRIEURE à /collectivites pour que Rails matche
  # d'abord la page marketing générique (routing par ordre déclaratif).
  get "/collectivites/:slug", to: "collectivites_portail#show",
                              as: :collectivite_portail,
                              constraints: { slug: /[a-z0-9-]+/ }

  get "/mentions-legales",    to: "pages#mentions_legales",   as: :mentions_legales
  get "/confidentialite",     to: "pages#confidentialite",    as: :confidentialite
  get "/contact",             to: "pages#contact",            as: :contact

  resources :properties do
    member do
      post :analyze
      post :publish
      post :unpublish
      post :confirm_address
      get  :preview
      patch :update_dpe_target
      patch :update_income_bracket
      patch :update_travaux
      patch :update_travaux_selection
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
