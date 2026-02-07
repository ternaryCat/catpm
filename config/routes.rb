Catpm::Engine.routes.draw do
  resources :status, only: [:index]
  resources :buckets, only: [:show]
  resources :samples, only: [:show]
  resources :errors, only: [:show]
end
