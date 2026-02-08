Catpm::Engine.routes.draw do
  resources :status, only: [:index]
  resources :system, only: [:index]
  get "endpoint", to: "endpoints#show", as: :endpoint
  resources :samples, only: [:show]
  resources :errors, only: [:index, :show, :destroy] do
    collection do
      post :resolve_all
    end
    member do
      patch :resolve
      patch :unresolve
    end
  end
end
