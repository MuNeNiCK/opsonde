defmodule OpsondeWeb.API.V1.ProviderController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Providers
  alias OpsondeWeb.API.{Pagination, Response}
  alias OpsondeWeb.API.V1.ProviderJSON

  @update_fields ~w(name configuration credentials)

  def index(conn, params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, providers} <-
           Providers.page_providers(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, providers, &ProviderJSON.data/1)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, provider} <- Providers.get_provider(id, actor: conn.assigns.current_user) do
      Response.data(conn, ProviderJSON.data(provider))
    end
  end

  def create(
        conn,
        %{
          "provider" => %{
            "name" => name,
            "kind" => kind,
            "adapter_type" => adapter_type,
            "configuration" => configuration,
            "credentials" => credentials
          }
        }
      ) do
    with {:ok, provider} <-
           Providers.create_provider(
             name,
             kind,
             adapter_type,
             configuration,
             credentials,
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, ProviderJSON.data(provider), :created)
    end
  end

  def create(_conn, _params), do: {:error, :bad_request}

  def update(
        conn,
        %{"id" => id, "provider" => %{"expected_revision" => expected_revision} = input}
      ) do
    attrs = attributes(input, @update_fields)

    if map_size(attrs) == 0 do
      {:error, :bad_request}
    else
      with {:ok, provider} <- Providers.get_provider(id, actor: conn.assigns.current_user),
           {:ok, updated} <-
             Providers.update_provider(provider, expected_revision, attrs,
               actor: conn.assigns.current_user
             ) do
        Response.data(conn, ProviderJSON.data(updated))
      end
    end
  end

  def update(_conn, _params), do: {:error, :bad_request}

  def check(
        conn,
        %{"id" => id, "provider" => %{"expected_revision" => expected_revision} = input}
      ) do
    with {:ok, provider} <-
           Providers.check_provider(
             id,
             expected_revision,
             Map.get(input, "check_input", %{}),
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, ProviderJSON.data(provider))
    end
  end

  def check(_conn, _params), do: {:error, :bad_request}

  def enable(conn, params), do: set_enabled(conn, params, :enable)
  def disable(conn, params), do: set_enabled(conn, params, :disable)

  defp set_enabled(
         conn,
         %{"id" => id, "provider" => %{"expected_revision" => expected_revision}},
         operation
       ) do
    with {:ok, provider} <- Providers.get_provider(id, actor: conn.assigns.current_user),
         {:ok, updated} <- change_enabled(provider, expected_revision, operation, conn) do
      Response.data(conn, ProviderJSON.data(updated))
    end
  end

  defp set_enabled(_conn, _params, _operation), do: {:error, :bad_request}

  defp change_enabled(provider, revision, :enable, conn),
    do: Providers.enable_provider(provider, revision, actor: conn.assigns.current_user)

  defp change_enabled(provider, revision, :disable, conn),
    do: Providers.disable_provider(provider, revision, actor: conn.assigns.current_user)

  defp attributes(input, fields) do
    fields
    |> Enum.reduce(%{}, fn field, attrs ->
      case Map.fetch(input, field) do
        {:ok, value} -> Map.put(attrs, String.to_existing_atom(field), value)
        :error -> attrs
      end
    end)
  end
end
