Rails.application.routes.draw do
  mount Catpm::Engine => "/catpm"

  get "test/index" => "test#index"
  get "test/slow" => "test#slow"
  get "test/error" => "test#error"

  get "demo" => "demo#index"
  get "demo/fast" => "demo#fast"
  get "demo/slow" => "demo#slow"
  get "demo/db_heavy" => "demo#db_heavy"
  get "demo/users" => "demo#users"
  get "demo/error" => "demo#error"
  get "demo/custom_trace" => "demo#custom_trace"
  get "demo/flush" => "demo#flush"
end
