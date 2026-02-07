Catpm::Engine.routes.draw do
  resources :status, only: [:index]
  get "endpoint", to: "endpoints#show", as: :endpoint
  resources :samples, only: [:show]
  resources :errors, only: [:show]
end
