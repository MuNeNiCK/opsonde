defmodule OpsondeWeb.Router do
  use OpsondeWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated_api do
    plug OpsondeWeb.API.Auth
  end

  scope "/api/v1", OpsondeWeb.API.V1 do
    pipe_through :api

    post "/accounts/bootstrap", AccountController, :bootstrap
    post "/sessions", SessionController, :create
  end

  scope "/api/v1", OpsondeWeb.API.V1 do
    pipe_through [:api, :authenticated_api]

    get "/session", SessionController, :show
    delete "/session", SessionController, :delete
    get "/accounts", AccountController, :index
    post "/accounts", AccountController, :create
    patch "/accounts/:id/role", AccountController, :update_role

    get "/providers", ProviderController, :index
    post "/providers", ProviderController, :create
    get "/providers/:id", ProviderController, :show
    patch "/providers/:id", ProviderController, :update
    post "/providers/:id/check", ProviderController, :check
    post "/providers/:id/enable", ProviderController, :enable
    post "/providers/:id/disable", ProviderController, :disable

    get "/ai-usage-role-assignments", AIUsageRoleAssignmentController, :index
    post "/ai-usage-role-assignments", AIUsageRoleAssignmentController, :create
    patch "/ai-usage-role-assignments/:id", AIUsageRoleAssignmentController, :update
  end

  scope "/api/v1", OpsondeWeb do
    pipe_through :api

    match :*, "/*path", APIErrorController, :not_found
  end

  scope "/api", OpsondeWeb do
    pipe_through :api

    post "/signals/alertmanager/:provider_id", SignalWebhookController, :alertmanager
    post "/signals/zabbix/:provider_id", SignalWebhookController, :zabbix

    match :*, "/*path", APIErrorController, :not_found
  end

  scope "/", OpsondeWeb do
    get "/*path", SPAController, :index
  end
end
