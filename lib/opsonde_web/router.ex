defmodule OpsondeWeb.Router do
  use OpsondeWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
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
