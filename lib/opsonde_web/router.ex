defmodule OpsondeWeb.Router do
  use OpsondeWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", OpsondeWeb do
    pipe_through :api

    match :*, "/*path", APIErrorController, :not_found
  end

  scope "/", OpsondeWeb do
    get "/*path", SPAController, :index
  end
end
