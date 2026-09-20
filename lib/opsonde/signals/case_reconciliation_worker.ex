defmodule Opsonde.Signals.CaseReconciliationWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :resolver,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  alias Opsonde.{Cases, Targets}
  alias Opsonde.Targets.ExternalIdentity

  @external_identity_module inspect(ExternalIdentity)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"change_key" => change_key}}) when is_binary(change_key) do
    with {:ok, incidents} <- Cases.unresolved_signal_cases_without_target(authorize?: false),
         {:ok, identity} <- changed_identity(change_key) do
      result =
        Enum.reduce_while(incidents, {:ok, false}, fn incident, {:ok, busy?} ->
          case wake(incident, change_key, identity) do
            :ok -> {:cont, {:ok, busy?}}
            :busy -> {:cont, {:ok, true}}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)

      case result do
        {:ok, true} -> {:error, "Signal Case still has an active Resolver Turn"}
        {:ok, false} -> :ok
        {:error, _error} = error -> error
      end
    end
  end

  def perform(_job), do: {:cancel, "Signal Case reconciliation arguments are invalid"}

  defp wake(%{status: :running} = incident, change_key, _identity) do
    with {:ok, run} <- Cases.active_resolution_run(incident.id, authorize?: false),
         {:ok, started} <- Cases.started_turns_for_run(run.id, authorize?: false) do
      if started == [] do
        start_turn(incident, run, change_key)
      else
        :busy
      end
    end
  end

  defp wake(%{status: :needs_attention} = incident, _change_key, %ExternalIdentity{} = identity) do
    if matching_identity?(incident, identity) do
      case Cases.resume_case_after_target_registration(
             incident.id,
             identity.id,
             identity.revision,
             authorize?: false
           ) do
        {:ok, _run} -> :ok
        {:error, _error} = error -> error
      end
    else
      :ok
    end
  end

  defp wake(%{status: :needs_attention}, _change_key, nil), do: :ok

  defp start_turn(incident, run, change_key) do
    key = "target-catalog:" <> digest([incident.id, change_key])

    case Cases.start_turn(
           incident.id,
           run.id,
           key,
           %{"objective" => "Re-evaluate the incident after the Target catalog changed"},
           %{"action" => "continue"},
           "Review Resolver limits",
           authorize?: false
         ) do
      {:ok, %{status: status}} when status in [:charged, :duplicate, :exhausted] -> :ok
      {:error, _error} = error -> already_started_or(error, run.id)
    end
  end

  defp already_started_or(error, run_id) do
    case Cases.started_turns_for_run(run_id, authorize?: false) do
      {:ok, [_started | _rest]} -> :ok
      _missing -> error
    end
  end

  defp digest(parts) do
    raw = Enum.join(parts, ":")
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end

  defp changed_identity(change_key) do
    case String.split(change_key, ":") do
      [@external_identity_module, id, revision] ->
        case Integer.parse(revision) do
          {revision, ""} ->
            case Targets.get_external_identity(id, authorize?: false) do
              {:ok, %{revision: ^revision} = identity} -> {:ok, identity}
              {:ok, _changed_identity} -> {:ok, nil}
              {:error, _error} = error -> error
            end

          :error ->
            {:error, "Target catalog change key is invalid"}
        end

      _other ->
        {:ok, nil}
    end
  end

  defp matching_identity?(
         %{
           pending_intent: %{"action" => "provide_human_input"},
           source: source,
           initial_context: %{"target_ref" => %{"kind" => kind, "value" => value}}
         },
         %{source: source, kind: kind, value: value, active: true}
       ),
       do: true

  defp matching_identity?(_incident, _identity), do: false
end
