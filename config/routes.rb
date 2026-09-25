Rails.application.routes.draw do
  # The browser demo. In development, test and behind Thruster,
  # ActionDispatch::Static serves public/index.html for "/" before the router
  # reaches this - see MetaController#show.
  root "meta#show"

  namespace :api do
    namespace :v1 do
      # Unauthenticated service description - the machine-readable front door,
      # for clients and agents that want JSON rather than the demo page.
      get "/", to: "/meta#describe", as: :meta

      # Unauthenticated. See Api::V1::HealthController for why it probes nothing.
      get "health", to: "health#show", as: :health

      # Requires X-API-Key.
      resources :checks, only: [ :create ]
    end
  end

  # Rails' own boot check, kept for load balancers and uptime monitors that are
  # already pointed at /up. Returns 200 if the app boots with no exceptions.
  get "up" => "rails/health#show", as: :rails_health_check
end
