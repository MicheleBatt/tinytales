Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root "posts#index"
  resources :posts do
    member do
      patch :publish
      patch :schedule
      patch :unpublish
      patch :resync
      get :preview, path: "anteprima"
    end
  end

  # La chat con l'assistente nelle pagine di creazione e modifica dei post.
  post "assistente/messaggi", to: "assistant_messages#create", as: :assistant_messages
  get "assistente/file/:token/:name", to: "assistant_files#show", as: :assistant_file,
      constraints: { name: /[^\/]+/ }, format: false

  # «Proponi post con Claude» dall'elenco: proposte in background, da approvare o annullare.
  post "proposte", to: "post_suggestions#create", as: :post_suggestions
  post "proposte/:token/approva", to: "post_suggestions#approve", as: :approve_post_suggestions
  delete "proposte/:token", to: "post_suggestions#destroy", as: :post_suggestion
  get "proposte/:token/file/:name", to: "post_suggestions#file", as: :post_suggestion_file,
      constraints: { name: /[^\/]+/ }, format: false
end
