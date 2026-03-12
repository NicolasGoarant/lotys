Rails.application.routes.draw do
  get "pages/home"
  devise_for :users

  root "pages#home"
  get "/a-propos", to: "pages#about", as: :about

  resources :properties do
    member do
      post :analyze
      post :publish
    end
    resources :documents, only: [:new, :create, :destroy]
    resources :offers, only: [:new, :create]
  end

  resources :offers, only: [:index, :update]
end
