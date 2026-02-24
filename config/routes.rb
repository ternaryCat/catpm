# frozen_string_literal: true

Catpm::Engine.routes.draw do
  root 'status#index'
  resources :status, only: [:index]
  resources :system, only: [:index]
  get 'endpoint', to: 'endpoints#show', as: :endpoint
  delete 'endpoint', to: 'endpoints#destroy'
  patch 'endpoint/pin', to: 'endpoints#toggle_pin', as: :endpoint_pin
  patch 'endpoint/ignore', to: 'endpoints#toggle_ignore', as: :endpoint_ignore
  get 'endpoints/ignored', to: 'endpoints#ignored', as: :ignored_endpoints
  resources :samples, only: [:show, :destroy]
  resources :events, only: [:index, :show, :destroy], param: :name do
    collection do
      delete 'samples/:sample_id', to: 'events#destroy_sample', as: :destroy_sample
    end
  end
  patch 'events/:name/pin', to: 'events#toggle_pin', as: :event_pin
  patch 'events/:name/ignore', to: 'events#toggle_ignore', as: :event_ignore
  get 'events_ignored', to: 'events#ignored', as: :ignored_events
  resources :errors, only: [:index, :show, :destroy] do
    collection do
      post :resolve_all
    end
    member do
      patch :resolve
      patch :unresolve
      patch :toggle_pin
    end
  end
end
