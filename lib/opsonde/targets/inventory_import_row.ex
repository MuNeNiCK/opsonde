defmodule Opsonde.Targets.InventoryImportRow do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "inventory_import_rows"
    repo Opsonde.Repo

    custom_indexes do
      index [:inventory_import_id]
      index [:target_id]
    end
  end

  actions do
    defaults [:read]

    read :for_import do
      argument :inventory_import_id, :uuid, allow_nil?: false
      filter expr(inventory_import_id == ^arg(:inventory_import_id))
      prepare build(sort: [position: :asc])
    end

    read :page_for_import do
      argument :inventory_import_id, :uuid, allow_nil?: false
      filter expr(inventory_import_id == ^arg(:inventory_import_id))
      pagination keyset?: true, required?: true, default_limit: 100, max_page_size: 500
      prepare build(sort: [position: :asc, id: :asc])
    end

    create :create do
      accept [
        :inventory_import_id,
        :position,
        :disposition,
        :identity_source,
        :identity_kind,
        :identity_value,
        :candidate,
        :provenance,
        :errors,
        :target_id,
        :target_revision
      ]

      validate {Opsonde.Validations.BoundedMap, attribute: :candidate}
      validate {Opsonde.Validations.BoundedMap, attribute: :provenance}
    end
  end

  policies do
    policy action([:for_import, :create]) do
      forbid_if always()
    end

    policy action([:read, :page_for_import]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :position, :integer do
      allow_nil? false
      public? true
      constraints min: 1, max: 100_000
    end

    attribute :disposition, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:create, :update, :error]
    end

    attribute :identity_source, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :identity_kind, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 80
    end

    attribute :identity_value, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :candidate, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :provenance, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :errors, {:array, :string} do
      allow_nil? false
      public? true
      default []
      constraints max_length: 20, items: [min_length: 1, max_length: 500]
    end

    attribute :target_revision, :integer do
      public? true
      constraints min: 1
    end

    timestamps()
  end

  relationships do
    belongs_to :inventory_import, Opsonde.Targets.InventoryImport do
      allow_nil? false
      public? true
    end

    belongs_to :target, Opsonde.Targets.Target do
      public? true
    end
  end

  identities do
    identity :unique_import_position, [:inventory_import_id, :position]
  end
end
