defmodule OpsondeWeb.Router do
  use OpsondeWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", OpsondeWeb do
    pipe_through :api
  end
end
