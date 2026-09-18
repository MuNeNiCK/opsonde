defmodule Opsonde.Cases.Evidence do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Cases,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "evidences"
    repo Opsonde.Repo

    custom_indexes do
      index [:case_id]
      index [:resolution_run_id]
      index [:turn_id]
    end
  end

  actions do
    defaults [:read]

    read :projection_window do
      argument :case_id, :uuid, allow_nil?: false
      argument :resolution_run_id, :uuid, allow_nil?: false

      filter expr(case_id == ^arg(:case_id) and resolution_run_id == ^arg(:resolution_run_id))

      prepare build(
                sort: [observed_at: :desc, inserted_at: :desc, id: :desc],
                limit: 100
              )
    end

    read :by_idempotency do
      get? true
      argument :case_id, :uuid, allow_nil?: false

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      filter expr(case_id == ^arg(:case_id) and idempotency_key == ^arg(:idempotency_key))
    end

    create :create_record do
      accept [
        :case_id,
        :resolution_run_id,
        :turn_id,
        :idempotency_key,
        :kind,
        :source,
        :source_ref,
        :content,
        :observed_at
      ]

      validate {Opsonde.Validations.BoundedMap, attribute: :content}
    end

    action :append, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :case_id, :uuid, allow_nil?: false
      argument :resolution_run_id, :uuid, allow_nil?: false
      argument :turn_id, :uuid

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      argument :kind, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 80]

      argument :source, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 120]

      argument :source_ref, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      argument :content, :map, allow_nil?: false
      argument :observed_at, :utc_datetime_usec, allow_nil?: false
      run Opsonde.Cases.Evidence.Actions.Append
    end
  end

  policies do
    policy action([:projection_window, :by_idempotency, :create_record, :append]) do
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

    attribute :idempotency_key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :kind, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 80
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :source_ref, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :content, :map do
      allow_nil? false
      public? true
    end

    attribute :observed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :case, Opsonde.Cases.Case do
      allow_nil? false
      public? true
    end

    belongs_to :resolution_run, Opsonde.Cases.ResolutionRun do
      allow_nil? false
      public? true
    end

    belongs_to :turn, Opsonde.Cases.Turn do
      public? true
    end
  end

  identities do
    identity :unique_idempotency, [:case_id, :idempotency_key]
  end
end
