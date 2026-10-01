defmodule Opsonde.FileEvidenceTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Targets}

  setup do
    admin =
      Accounts.bootstrap!(
        "file-evidence-admin@example.invalid",
        "test-only-password",
        "test-only-password"
      )

    operator =
      Accounts.create_user!(
        "file-evidence-owner@example.invalid",
        "test-only-password",
        :operator,
        actor: admin
      )

    target =
      Targets.create_target!("file-evidence-host", "host", "custom-os", %{}, nil, actor: admin)

    incident =
      Cases.open_case!(
        :manual,
        "fixture",
        "file-evidence",
        "Inspect captured file",
        :warning,
        %{
          "observed_problem" => "unknown file contents",
          "desired_outcome" => "identify the file contents"
        },
        target.id,
        :en,
        actor: operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    %{admin: admin, operator: operator, target: target, incident: incident, run: run}
  end

  test "a file read is citable metadata while exact binary contents are read only for projection",
       context do
    {source, reference} = source!(context)
    turn = turn!(context, source, reference)

    evidence = Cases.capture_file_read!(turn.id, authorize?: false)
    assert evidence.kind == "file_read"
    assert evidence.case_id == context.incident.id
    assert evidence.turn_id == turn.id
    assert evidence.content["source_evidence_id"] == source.id
    assert evidence.content["source_observed_at"] == DateTime.to_iso8601(source.observed_at)
    assert evidence.content["reference"] == reference
    assert evidence.content["offset"] == 1
    assert evidence.content["byte_count"] == 3

    assert evidence.content["sha256"] ==
             "ae4b3280e56e2faf83f414a6e3dabe9d5fbe18976544c05fed121accb85b53fc"

    refute Map.has_key?(evidence.content, "value")
    refute Map.has_key?(evidence.content, "encoding")

    content = Cases.read_file_content!(evidence.id, context.incident.id, authorize?: false)
    assert content["encoding"] == "utf8"
    assert content["value"] == <<0, 1, 2>>
    assert content["next_offset"] == 4
    assert content["eof"] == false
    assert Cases.get_evidence!(evidence.id, actor: context.operator).content == evidence.content
    assert Cases.capture_file_read!(turn.id, authorize?: false).id == evidence.id

    continued = turn!(context, evidence, reference, %{"offset" => 4, "length" => 8})
    tail = Cases.capture_file_read!(continued.id, authorize?: false)
    assert tail.content["source_observed_at"] == DateTime.to_iso8601(source.observed_at)
    assert tail.content["source_evidence_id"] == evidence.id

    assert Cases.read_file_content!(tail.id, context.incident.id, authorize?: false)["value"] ==
             "/w=="

    assert Cases.get_resolution_run!(context.run.id, authorize?: false).target_request_count == 0
    assert Cases.get_resolution_run!(context.run.id, authorize?: false).effect_count == 0
  end

  test "non-UTF8 bytes and empty files retain exact encoding and EOF", context do
    {source, reference} = source!(context)
    turn = turn!(context, source, reference, %{"offset" => 0, "length" => 8})
    evidence = Cases.capture_file_read!(turn.id, authorize?: false)
    content = Cases.read_file_content!(evidence.id, context.incident.id, authorize?: false)
    assert content["encoding"] == "base64"
    assert content["value"] == "/wABAv8="
    assert content["byte_count"] == 5
    assert content["next_offset"] == 5
    assert content["eof"]

    {source, reference} = source!(context, empty?: true)
    turn = turn!(context, source, reference, %{"offset" => 0, "length" => 8})
    evidence = Cases.capture_file_read!(turn.id, authorize?: false)
    content = Cases.read_file_content!(evidence.id, context.incident.id, authorize?: false)
    assert content["encoding"] == "utf8"
    assert content["value"] == ""
    assert content["byte_count"] == 0
    assert content["next_offset"] == 0
    assert content["eof"]
  end

  test "capture requires an exact cited reference and finite selected-Target range", context do
    {source, reference} = source!(context)

    for override <- [
          %{"reference" => Map.put(reference, "target_id", Ecto.UUID.generate())},
          %{"reference" => Map.put(reference, "sha256", String.duplicate("0", 64))},
          %{"source_evidence_id" => Ecto.UUID.generate()},
          %{"offset" => 6},
          %{"offset" => -1},
          %{"length" => 8_193},
          %{"length" => 0}
        ] do
      turn = turn!(context, source, reference, override)
      assert {:error, _} = Cases.capture_file_read(turn.id, authorize?: false)
    end

    assert [persisted] = Cases.list_evidence!(actor: context.operator)
    assert persisted.id == source.id
    assert persisted.content == source.content
    turn = turn!(context, source, reference)
    assert {:error, _} = Cases.capture_file_read(turn.id, actor: context.admin)
  end

  test "each content projection checks current owner authority and revocation", context do
    {source, reference} = source!(context)
    turn = turn!(context, source, reference)
    evidence = Cases.capture_file_read!(turn.id, authorize?: false)
    viewer = Accounts.change_role!(context.operator, :viewer, actor: context.admin)

    assert {:error, error} =
             Cases.read_file_content(evidence.id, context.incident.id, authorize?: false)

    assert Exception.message(error) =~ "Case owner cannot read"
    assert {:error, _} = Cases.capture_file_read(turn.id, authorize?: false)
    owner = Accounts.change_role!(viewer, :operator, actor: context.admin)

    assert Cases.read_file_content!(evidence.id, context.incident.id, authorize?: false)["value"] ==
             <<0, 1, 2>>

    assert Cases.capture_file_read!(turn.id, authorize?: false).id == evidence.id
    Targets.revoke_artifact!(reference["id"], actor: owner)

    assert {:error, _} =
             Cases.read_file_content(evidence.id, context.incident.id, authorize?: false)

    assert {:error, _} = Cases.capture_file_read(turn.id, authorize?: false)
  end

  test "a file visible in another Case cannot be cited as this Case's source", context do
    other =
      Cases.open_case!(
        :manual,
        "fixture",
        "foreign-file-source",
        "Another investigation",
        :warning,
        %{
          "observed_problem" => "unknown file contents",
          "desired_outcome" => "identify contents"
        },
        context.target.id,
        :en,
        actor: context.operator
      )

    other_run = Cases.active_resolution_run!(other.id, authorize?: false)
    {source, reference} = source!(%{context | incident: other, run: other_run})
    turn = turn!(context, source, reference)
    assert {:error, error} = Cases.capture_file_read(turn.id, authorize?: false)
    assert Exception.message(error) =~ "not present in the cited Case Evidence"
    refute Enum.any?(Cases.list_evidence!(actor: context.operator), &(&1.kind == "file_read"))
  end

  test "another uploader, another Case and cancellation cannot disclose file contents",
       context do
    other =
      Accounts.create_user!("other-file-owner@example.invalid", "test-only-password", :operator,
        actor: context.admin
      )

    {source, reference} = source!(context, actor: other)
    turn = turn!(context, source, reference)
    assert {:error, _} = Cases.capture_file_read(turn.id, authorize?: false)
    {source, reference} = source!(context)
    turn = turn!(context, source, reference)
    evidence = Cases.capture_file_read!(turn.id, authorize?: false)

    assert {:error, _} =
             Cases.read_file_content(evidence.id, Ecto.UUID.generate(), authorize?: false)

    current = Cases.get_case!(context.incident.id, actor: context.operator)
    Cases.request_case_cancellation!(current.id, current.revision, actor: context.operator)

    assert {:error, _} =
             Cases.read_file_content(evidence.id, context.incident.id, authorize?: false)

    assert {:error, _} = Cases.capture_file_read(turn.id, authorize?: false)
  end

  test "an expired file cannot be projected from an already saved receipt", context do
    previous = Application.get_env(:opsonde, :artifact_limits)
    Application.put_env(:opsonde, :artifact_limits, %{lifetime_seconds: 1})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:opsonde, :artifact_limits, previous),
        else: Application.delete_env(:opsonde, :artifact_limits)
    end)

    {source, reference} = source!(context)
    turn = turn!(context, source, reference)
    evidence = Cases.capture_file_read!(turn.id, authorize?: false)
    Process.sleep(1_050)

    assert {:error, _} =
             Cases.read_file_content(evidence.id, context.incident.id, authorize?: false)

    assert {:error, _} = Cases.capture_file_read(turn.id, authorize?: false)
  end

  test "a failed receipt event saves nothing and retry publishes one citable receipt", context do
    {source, reference} = source!(context)
    turn = turn!(context, source, reference)

    Opsonde.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_file_read_event() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.event_type = 'evidence_added' AND NEW.data->>'kind' = 'file_read' THEN
        RAISE EXCEPTION 'injected file receipt event failure';
      END IF;
      RETURN NEW;
    END; $$;
    """)

    Opsonde.Repo.query!("""
    CREATE TRIGGER reject_file_read_event BEFORE INSERT ON case_events
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_file_read_event();
    """)

    assert {:error, _} = Cases.capture_file_read(turn.id, authorize?: false)
    assert [persisted] = Cases.list_evidence!(actor: context.operator)
    assert persisted.id == source.id
    assert persisted.content == source.content
    Opsonde.Repo.query!("DROP TRIGGER reject_file_read_event ON case_events")
    receipt = Cases.capture_file_read!(turn.id, authorize?: false)
    assert Cases.capture_file_read!(turn.id, authorize?: false).id == receipt.id

    assert Enum.count(Cases.list_evidence!(actor: context.operator), &(&1.kind == "file_read")) ==
             1

    assert Cases.read_file_content!(receipt.id, context.incident.id, authorize?: false)["value"] ==
             <<0, 1, 2>>
  end

  test "changed range integrity metadata and Target revision reject projection", context do
    {source, reference} = source!(context)
    turn = turn!(context, source, reference)
    receipt = Cases.capture_file_read!(turn.id, authorize?: false)
    {:ok, id} = Ecto.UUID.dump(receipt.id)
    # Persisted receipt fault; the observable read remains the public Ash action.
    Opsonde.Repo.query!(
      "UPDATE evidences SET content = jsonb_set(content, '{byte_count}', '4') WHERE id = $1",
      [id]
    )

    assert {:error, error} =
             Cases.read_file_content(receipt.id, context.incident.id, authorize?: false)

    assert Exception.message(error) =~ "integrity check failed"

    Opsonde.Repo.query!(
      "UPDATE evidences SET content = jsonb_set(content, '{byte_count}', '3') WHERE id = $1",
      [id]
    )

    Targets.update_target!(
      context.target,
      context.target.revision,
      %{operating_instructions: "Inspect current target"},
      actor: context.admin
    )

    assert {:error, error} =
             Cases.read_file_content(receipt.id, context.incident.id, authorize?: false)

    assert Exception.message(error) =~ "Target changed"
  end

  defp source!(context, opts \\ []) do
    empty? = Keyword.get(opts, :empty?, false)
    actor = Keyword.get(opts, :actor, context.operator)
    key = Ecto.UUID.generate()

    upload =
      Targets.begin_artifact!(
        context.target.id,
        "capture.bin",
        "application/octet-stream",
        if(empty?, do: 0, else: 5),
        if(empty?,
          do: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          else: "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"
        ),
        key,
        actor: actor
      )

    unless empty? do
      Targets.append_artifact_chunk!(upload.id, 0, <<255, 0>>, actor: actor)
      Targets.append_artifact_chunk!(upload.id, 2, <<1, 2, 255>>, actor: actor)
    end

    Targets.complete_artifact!(upload.id, actor: actor)
    reference = Targets.artifact_reference!(upload.id, context.target.id, actor: actor)

    source =
      Cases.append_evidence!(
        context.incident.id,
        context.run.id,
        nil,
        key,
        "observation",
        "fixture",
        key,
        %{"target_id" => context.target.id, "facts" => %{"steps" => [%{"file" => reference}]}},
        DateTime.utc_now(),
        authorize?: false
      )

    {source, reference}
  end

  defp turn!(context, source, reference, overrides \\ %{}) do
    started =
      Cases.start_turn!(
        context.incident.id,
        context.run.id,
        Ecto.UUID.generate(),
        %{},
        %{},
        "Review limits",
        authorize?: false
      )

    Cases.complete_turn!(
      started.value.id,
      started.value.revision,
      %{
        "outcome" => "decision",
        "intent" =>
          Map.merge(
            %{
              "type" => "file_read",
              "source_evidence_id" => source.id,
              "reference" => reference,
              "offset" => 1,
              "length" => 3,
              "reason" => "Read the captured native response"
            },
            overrides
          )
      },
      :observation_pending,
      %{},
      "Review limits",
      authorize?: false
    ).value
  end
end
