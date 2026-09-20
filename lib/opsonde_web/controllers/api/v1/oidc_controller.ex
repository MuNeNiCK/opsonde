defmodule OpsondeWeb.API.V1.OIDCController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Accounts
  alias Opsonde.Accounts.OIDCProvider
  alias OpsondeWeb.API.Response

  def status(conn, _params) do
    enabled = Accounts.oidc_available?()

    Response.data(conn, %{
      enabled: enabled,
      authorization_url: if(enabled, do: Opsonde.Secrets.public_url("/auth/user/oidc")),
      callback_uri: Opsonde.Secrets.oidc_callback_uri()
    })
  end

  def show_provider(conn, _params) do
    case Accounts.current_oidc_provider(actor: conn.assigns.current_user) do
      {:ok, %OIDCProvider{} = provider} ->
        Response.data(conn, provider_data(provider))

      {:ok, nil} ->
        Response.data(conn, %{
          enabled: false,
          callback_uri: Opsonde.Secrets.oidc_callback_uri()
        })

      {:error,
       %Ash.Error.Invalid{
         errors: [%Ash.Error.Query.NotFound{resource: OIDCProvider}]
       }} ->
        Response.data(conn, %{
          enabled: false,
          callback_uri: Opsonde.Secrets.oidc_callback_uri()
        })

      {:error, error} ->
        {:error, error}
    end
  end

  def configure_provider(
        conn,
        %{
          "oidc_provider" =>
            %{
              "issuer" => issuer,
              "client_id" => client_id,
              "client_secret" => client_secret
            } = input
        }
      ) do
    with {:ok, provider} <-
           Accounts.configure_oidc(
             %{
               issuer: issuer,
               client_id: client_id,
               client_secret: client_secret,
               id_token_alg: Map.get(input, "id_token_alg", "RS256"),
               enabled: Map.get(input, "enabled", true)
             },
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, provider_data(provider))
    end
  end

  def configure_provider(_conn, _params), do: {:error, :bad_request}

  def create_link_request(conn, _params) do
    with {:ok, %{request: request, start_token: start_token}} <-
           Accounts.request_oidc_link(actor: conn.assigns.current_user) do
      Response.data(
        conn,
        %{
          authorization_url:
            Opsonde.Secrets.public_url(
              "/auth/oidc/start/#{request.id}?token=#{URI.encode_www_form(start_token)}"
            ),
          expires_at: request.expires_at
        },
        :created
      )
    else
      _error -> {:error, :not_found}
    end
  end

  defp provider_data(provider) do
    %{
      id: provider.id,
      issuer: provider.issuer,
      client_id: provider.client_id,
      id_token_alg: provider.id_token_alg,
      enabled: provider.enabled,
      revision: provider.revision,
      callback_uri: Opsonde.Secrets.oidc_callback_uri(),
      inserted_at: provider.inserted_at,
      updated_at: provider.updated_at
    }
  end
end
