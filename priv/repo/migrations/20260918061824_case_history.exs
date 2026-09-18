defmodule Opsonde.Repo.Migrations.CaseHistory do
  use Ecto.Migration

  def change do
    create table(:turns, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :ordinal, :bigint, null: false
      add :idempotency_key, :text, null: false
      add :status, :text, null: false
      add :intent, :map, null: false
      add :result, :map, null: false, default: %{}
      add :result_digest, :text
      add :progress_kind, :text
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :revision, :bigint, null: false, default: 1

      add :case_id,
          references(:cases, name: "turns_case_id_fkey", type: :uuid, prefix: "public"),
          null: false

      add :resolution_run_id,
          references(:resolution_runs,
            name: "turns_resolution_run_id_fkey",
            type: :uuid,
            prefix: "public"
          ),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:turns, [:resolution_run_id, :idempotency_key],
             name: "turns_unique_idempotency_index"
           )

    create unique_index(:turns, [:resolution_run_id, :ordinal],
             name: "turns_unique_ordinal_index"
           )

    create index(:turns, [:case_id])
    create index(:turns, [:resolution_run_id])

    create table(:evidences, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :idempotency_key, :text, null: false
      add :kind, :text, null: false
      add :source, :text, null: false
      add :source_ref, :text, null: false
      add :content, :map, null: false
      add :observed_at, :utc_datetime_usec, null: false

      add :case_id,
          references(:cases, name: "evidences_case_id_fkey", type: :uuid, prefix: "public"),
          null: false

      add :resolution_run_id,
          references(:resolution_runs,
            name: "evidences_resolution_run_id_fkey",
            type: :uuid,
            prefix: "public"
          ),
          null: false

      add :turn_id,
          references(:turns, name: "evidences_turn_id_fkey", type: :uuid, prefix: "public")

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:evidences, [:case_id, :idempotency_key],
             name: "evidences_unique_idempotency_index"
           )

    create index(:evidences, [:case_id])
    create index(:evidences, [:resolution_run_id])
    create index(:evidences, [:turn_id])
  end
end
