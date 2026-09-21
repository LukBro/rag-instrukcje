# Dopisz do config/routes.rb (wewnątrz Rails.application.routes.draw do ... end):
get "/pomoc", to: "search#index", as: :search
get "/pomoc/odpowiedz", to: "answers#show", as: :answer
get "/pomoc/:id", to: "docs#show", as: :doc, constraints: { id: /[0-9a-f]{16}/ }
