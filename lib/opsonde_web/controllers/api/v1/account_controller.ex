defmodule OpsondeWeb.API.V1.AccountController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Accounts
  alias OpsondeWeb.API.{Pagination, Response}
  alias OpsondeWeb.API.V1.AccountJSON

  def bootstrap(
        conn,
        %{
          "account" => %{
            "email" => email,
            "password" => password,
            "password_confirmation" => confirmation
          }
        }
      ) do
    with {:ok, user} <- Accounts.bootstrap(email, password, confirmation, authorize?: true) do
      Response.data(conn, AccountJSON.data(user), :created)
    end
  end

  def bootstrap(_conn, _params), do: {:error, :bad_request}

  def index(conn, params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, users} <-
           Accounts.list_users(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, users, &AccountJSON.data/1)
    end
  end

  def create(
        conn,
        %{"account" => %{"email" => email, "password" => password, "role" => role}}
      ) do
    with {:ok, user} <-
           Accounts.create_user(email, password, role, actor: conn.assigns.current_user) do
      Response.data(conn, AccountJSON.data(user), :created)
    end
  end

  def create(_conn, _params), do: {:error, :bad_request}

  def update_role(conn, %{"id" => id, "account" => %{"role" => role}}) do
    with {:ok, user} <- Accounts.get_user(id, actor: conn.assigns.current_user),
         {:ok, updated} <- Accounts.change_role(user, role, actor: conn.assigns.current_user) do
      Response.data(conn, AccountJSON.data(updated))
    end
  end

  def update_role(_conn, _params), do: {:error, :bad_request}
end
