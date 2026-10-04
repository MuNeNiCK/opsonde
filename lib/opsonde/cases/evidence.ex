defmodule Opsonde.Cases.Evidence do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Cases,
    authorizers: [Ash.Policy.Authorizer],
    simple_notifiers: [Opsonde.Cases.Case.RealtimeNotifier],
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

    read :page_for_case do
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id))
      pagination keyset?: true, required?: true, default_limit: 100, max_page_size: 500
      prepare build(sort: [observed_at: :desc, inserted_at: :desc, id: :desc])
      prepare build(load: [:summary])
    end

    read :projection_window do
      argument :case_id, :uuid, allow_nil?: false
      argument :resolution_run_id, :uuid, allow_nil?: false

      filter expr(case_id == ^arg(:case_id) and resolution_run_id == ^arg(:resolution_run_id))

      prepare build(
                sort: [observed_at: :desc, inserted_at: :desc, id: :desc],
                limit: 100
              )
    end

    read :signal_contexts do
      argument :case_id, :uuid, allow_nil?: false

      filter expr(case_id == ^arg(:case_id) and kind == "signal_event")

      prepare Opsonde.Cases.Evidence.Preparations.ActiveCondition

      prepare build(
                distinct: [:source, :source_ref],
                distinct_sort: [
                  source: :asc,
                  source_ref: :asc,
                  observed_at: :desc,
                  inserted_at: :desc,
                  id: :desc
                ],
                sort: [observed_at: :desc, inserted_at: :desc, id: :desc]
              )
    end

    read :target_continuity do
      argument :case_id, :uuid, allow_nil?: false

      filter expr(case_id == ^arg(:case_id) and kind == "target_verification")

      prepare build(
                sort: [observed_at: :desc, inserted_at: :desc, id: :desc],
                limit: 100
              )
    end

    read :review_context do
      argument :case_id, :uuid, allow_nil?: false

      filter expr(
               case_id == ^arg(:case_id) and
                 kind in ["observation", "operation_outcome", "target_verification", "file_read"]
             )

      prepare build(sort: [observed_at: :desc, inserted_at: :desc, id: :desc], limit: 100)
    end

    read :review_target_context do
      argument :case_id, :uuid, allow_nil?: false
      argument :target_id, :uuid, allow_nil?: false

      filter expr(
               case_id == ^arg(:case_id) and
                 kind in ["observation", "operation_outcome", "target_verification", "file_read"] and
                 get_path(stored_content, ["target_id"]) == ^arg(:target_id)
             )

      prepare build(sort: [observed_at: :desc, inserted_at: :desc, id: :desc], limit: 101)
    end

    read :condition_assessment_candidates do
      argument :case_id, :uuid, allow_nil?: false
      argument :after, :utc_datetime_usec, allow_nil?: false

      filter expr(
               case_id == ^arg(:case_id) and observed_at >= ^arg(:after) and
                 kind in ["observation", "target_verification", "file_read"]
             )

      prepare build(sort: [observed_at: :desc, inserted_at: :desc, id: :desc], limit: 257)
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
        :observed_at
      ]

      argument :content, :map, allow_nil?: false
      validate {Opsonde.Validations.BoundedMap, argument: :content}
      change set_attribute(:stored_content, arg(:content))
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

    action :capture_file_read, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :turn_id, :uuid, allow_nil?: false
      run {Opsonde.Cases.Evidence.Actions.FileRead, operation: :capture}
    end

    action :read_file_content, :map do
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :case_id, :uuid, allow_nil?: false
      run {Opsonde.Cases.Evidence.Actions.FileRead, operation: :read}
    end

    action :file_read_source, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :case_id, :uuid, allow_nil?: false
      run {Opsonde.Cases.Evidence.Actions.FileRead, operation: :source}
    end
  end

  policies do
    policy action([
             :projection_window,
             :signal_contexts,
             :target_continuity,
             :review_context,
             :condition_assessment_candidates,
             :by_idempotency,
             :create_record,
             :append,
             :capture_file_read,
             :read_file_content,
             :file_read_source
           ]) do
      forbid_if always()
    end

    policy action([:read, :page_for_case]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  preparations do
    prepare build(load: [:content]) do
      where negate(action_is(:page_for_case))
    end
  end

  changes do
    change load(:content), on: [:create]
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

    attribute :stored_content, :map do
      allow_nil? false
      source :content
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

  calculations do
    calculate :summary, :map, {Opsonde.Cases.Evidence.Calculations.Content, summary?: true} do
      public? true
    end

    calculate :content, :map, Opsonde.Cases.Evidence.Calculations.Content do
      public? true
    end
  end

  identities do
    identity :unique_idempotency, [:case_id, :idempotency_key]
  end
end
