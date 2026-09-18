defmodule OpsondeWeb.API.V1.InventoryImportController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Providers.Inventory
  alias Opsonde.Targets
  alias OpsondeWeb.API.{Pagination, Response}
  alias OpsondeWeb.API.V1.InventoryImportJSON

  def index(conn, params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, imports} <-
           Targets.page_inventory_imports(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, imports, &InventoryImportJSON.data/1)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, import} <- Targets.get_inventory_import(id, actor: conn.assigns.current_user) do
      Response.data(conn, InventoryImportJSON.data(import))
    end
  end

  def rows(conn, %{"id" => id} = params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, rows} <-
           Targets.page_inventory_import_rows(id,
             page: page,
             actor: conn.assigns.current_user
           ) do
      Response.page(conn, rows, &InventoryImportJSON.row/1)
    end
  end

  def preview_manual(conn, %{"inventory_import" => %{"source" => source, "csv" => csv}}) do
    with {:ok, import} <-
           Targets.preview_manual_inventory(source, csv, actor: conn.assigns.current_user) do
      Response.data(conn, InventoryImportJSON.data(import), :created)
    end
  end

  def preview_manual(_conn, _params), do: {:error, :bad_request}

  def preview_provider(
        conn,
        %{
          "inventory_import" =>
            %{
              "source" => source,
              "provider_id" => provider_id,
              "provider_revision" => provider_revision
            } = input
        }
      ) do
    request = %Inventory.Request{
      provider_revision: provider_revision,
      scope: input["scope"] || %{},
      max_pages: input["max_pages"] || 100
    }

    with {:ok, import} <-
           Targets.preview_provider_inventory(source, provider_id, request, %{},
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, InventoryImportJSON.data(import), :created)
    end
  end

  def preview_provider(_conn, _params), do: {:error, :bad_request}

  def apply_import(
        conn,
        %{
          "id" => id,
          "inventory_import" => %{
            "expected_revision" => expected_revision,
            "expected_digest" => expected_digest
          }
        }
      ) do
    with {:ok, import} <-
           Targets.apply_inventory_import(id, expected_revision, expected_digest,
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, InventoryImportJSON.data(import))
    end
  end

  def apply_import(_conn, _params), do: {:error, :bad_request}
end
