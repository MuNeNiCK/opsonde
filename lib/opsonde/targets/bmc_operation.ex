defmodule Opsonde.Targets.BMCOperation do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "bmc_operations"
    repo Opsonde.Repo

    custom_indexes do
      index [:access_method_id]
    end
  end

  actions do
    defaults [:read]

    read :available_for_method do
      argument :access_method_id, :uuid, allow_nil?: false

      filter expr(
               access_method_id == ^arg(:access_method_id) and active == true and
                 access_method.active == true
             )

      prepare build(sort: [name: :asc, id: :asc])
    end

    read :for_use do
      get? true
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :access_method_id, :uuid, allow_nil?: false

      filter expr(
               id == ^arg(:id) and revision == ^arg(:expected_revision) and
                 access_method_id == ^arg(:access_method_id) and active == true and
                 access_method.active == true
             )
    end

    create :create do
      primary? true

      accept [
        :access_method_id,
        :name,
        :description,
        :request_kind,
        :protocol_request,
        :input_schema,
        :output_schema,
        :verification_schema
      ]

      validate Opsonde.Targets.BMCOperation.Validations.Definition
    end

    update :update do
      primary? true
      require_atomic? false

      accept [
        :name,
        :description,
        :request_kind,
        :protocol_request,
        :input_schema,
        :output_schema,
        :verification_schema
      ]

      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      validate Opsonde.Validations.CurrentRevision
      validate Opsonde.Targets.BMCOperation.Validations.Definition
      change optimistic_lock(:revision)
    end

    update :deactivate do
      accept []
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Opsonde.Validations.CurrentRevision
      change set_attribute(:active, false)
      change optimistic_lock(:revision)
    end
  end

  policies do
    policy action([:create, :update, :deactivate]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action([:available_for_method, :for_use]) do
      forbid_if always()
    end

    policy action(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :description, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :request_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:observation, :effect]
    end

    attribute :protocol_request, :map do
      allow_nil? false
      public? true
    end

    attribute :input_schema, :map do
      allow_nil? false
      public? true
    end

    attribute :output_schema, :map do
      allow_nil? false
      public? true
    end

    attribute :verification_schema, :map do
      public? true
    end

    attribute :active, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :revision, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    timestamps()
  end

  relationships do
    belongs_to :access_method, Opsonde.Targets.AccessMethod do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_method_name, [:access_method_id, :name]
  end
end
