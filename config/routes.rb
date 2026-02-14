Catpm::Engine.routes.draw do
  root "status#index"
  resources :status, only: [:index]
  resources :system, only: [:index]
  get "endpoint", to: "endpoints#show", as: :endpoint
  resources :samples, only: [:show]
  resources :events, only: [:index, :show], param: :name
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
