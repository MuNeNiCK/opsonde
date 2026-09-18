defmodule Opsonde.Cases.CaseEvent do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Cases,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "case_events"
    repo Opsonde.Repo

    custom_indexes do
      index [:case_id]
      index [:resolution_run_id]
      index [:actor_id]
    end
  end

  actions do
    defaults [:read]

    read :timeline do
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :page_for_case do
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id))
      pagination keyset?: true, required?: true, default_limit: 100, max_page_size: 500
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :by_idempotency do
      get? true
      argument :case_id, :uuid, allow_nil?: false

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      filter expr(case_id == ^arg(:case_id) and idempotency_key == ^arg(:idempotency_key))
    end

    read :target_history do
      argument :case_id, :uuid, allow_nil?: false
      argument :resolution_run_id, :uuid, allow_nil?: false

      filter expr(
               case_id == ^arg(:case_id) and
                 resolution_run_id == ^arg(:resolution_run_id) and
                 event_type in ["case_opened", "case_target_selected", "related_target_traversed"]
             )

      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    create :create_record do
      accept [
        :case_id,
        :resolution_run_id,
        :actor_id,
        :event_type,
        :idempotency_key,
        :data
      ]

      validate {Opsonde.Validations.BoundedMap, attribute: :data}
    end
  end

  policies do
    policy action([:by_idempotency, :target_history, :create_record]) do
      forbid_if always()
    end

    policy action([:read, :timeline, :page_for_case]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :event_type, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 80
    end

    attribute :idempotency_key, :string do
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :data, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :case, Opsonde.Cases.Case do
      allow_nil? false
      public? true
    end

    belongs_to :resolution_run, Opsonde.Cases.ResolutionRun do
      public? true
    end

    belongs_to :actor, Opsonde.Accounts.User do
      public? true
    end
  end

  identities do
    identity :unique_idempotency, [:case_id, :idempotency_key]
  end
end
