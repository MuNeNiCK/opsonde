defmodule Opsonde.Cases.SignalIngress do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Opsonde.{Cases, Providers, Targets}

  alias Opsonde.Cases.{
    Case,
    CaseEvent,
    Evidence,
    ResolutionRun,
    SignalCorrelation,
    SignalEvent,
    SignalReceipt,
    Turn
  }

  alias Opsonde.Providers.Signal

  @impl true
  def run(input, _opts, _context) do
    arguments = input.arguments

    with {:ok, %Signal.IngestResult{} = result} <-
           Providers.signal_ingest(
             arguments.provider_id,
             arguments.provider_revision,
             arguments.envelope,
             arguments.invocation,
             authorize?: false
           ),
         digest <- digest(result),
         {:ok, correlations} <- ensure_correlations(arguments.provider_id, result),
         {:ok, receipt} <- persist(arguments, result, digest, correlations) do
      {:ok, receipt}
    end
  end

  defp ensure_correlations(provider_id, result) do
    result.events
    |> Enum.sort_by(& &1.event_key)
    |> Enum.reduce_while({:ok, %{}}, fn event, {:ok, correlations} ->
      case ensure_correlation(provider_id, result.receipt.source, event.event_key) do
        {:ok, correlation} ->
          {:cont, {:ok, Map.put(correlations, event.event_key, correlation.id)}}

        {:error, _error} = error ->
          {:halt, error}
      end
    end)
  end

  defp ensure_correlation(provider_id, source, event_key) do
    case correlation(provider_id, source, event_key) do
      {:ok, %SignalCorrelation{} = existing} ->
        {:ok, existing}

      {:ok, nil} ->
        create_correlation(provider_id, source, event_key)

      {:error, _error} = error ->
        error
    end
  end

  defp create_correlation(provider_id, source, event_key) do
    case Cases.create_signal_correlation_record(
           %{
             provider_id: provider_id,
             source: source,
             event_key: event_key,
             current_state: :pending,
             revision: 1
           },
           authorize?: false
         ) do
      {:ok, correlation} ->
        {:ok, correlation}

      {:error, _error} = failed ->
        case correlation(provider_id, source, event_key) do
          {:ok, %SignalCorrelation{} = existing} -> {:ok, existing}
          _missing -> failed
        end
    end
  end

  defp persist(arguments, result, digest, correlation_ids) do
    resources = [
      SignalCorrelation,
      SignalReceipt,
      SignalEvent,
      Case,
      ResolutionRun,
      Evidence,
      CaseEvent,
      Turn
    ]

    transaction = fn ->
      with {:ok, correlations} <- lock_correlations(correlation_ids),
           {:ok, existing} <- existing_receipt(arguments.provider_id, result.receipt.receipt_id) do
        if existing do
          validate_receipt_replay(existing, result, digest)
        else
          create_receipt_and_events(arguments, result, digest, correlations)
        end
      end
    end

    case Ash.transact(resources, transaction) do
      {:ok, {:ok, %SignalReceipt{} = receipt}} ->
        {:ok, receipt}

      {:error, _error} = failed ->
        case existing_receipt(arguments.provider_id, result.receipt.receipt_id) do
          {:ok, %SignalReceipt{} = receipt} -> validate_receipt_replay(receipt, result, digest)
          _missing -> failed
        end

      success ->
        success
    end
  end

  defp lock_correlations(correlation_ids) do
    correlation_ids
    |> Enum.sort_by(fn {event_key, _id} -> event_key end)
    |> Enum.reduce_while({:ok, %{}}, fn {event_key, id}, {:ok, locked} ->
      result =
        SignalCorrelation
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id: id)
        |> Ash.Query.lock(:for_update)
        |> Ash.read_one(authorize?: false)

      case result do
        {:ok, %SignalCorrelation{} = correlation} ->
          {:cont, {:ok, Map.put(locked, event_key, correlation)}}

        {:ok, nil} ->
          {:halt, {:error, "Signal correlation is unavailable"}}

        {:error, _error} = error ->
          {:halt, error}
      end
    end)
  end

  defp create_receipt_and_events(arguments, result, digest, correlations) do
    receipt = result.receipt

    with {:ok, persisted_receipt} <-
           Cases.create_signal_receipt_record(
             %{
               provider_id: arguments.provider_id,
               provider_revision: arguments.provider_revision,
               receipt_id: receipt.receipt_id,
               source: receipt.source,
               received_at: arguments.envelope.received_at,
               metadata: receipt.metadata,
               normalized_digest: digest,
               event_count: length(result.events)
             },
             authorize?: false
           ),
         {:ok, _processed} <-
           process_events(persisted_receipt, result.events, correlations) do
      {:ok, persisted_receipt}
    end
  end

  defp process_events(receipt, events, correlations) do
    events
    |> Enum.sort_by(& &1.event_key)
    |> Enum.reduce_while({:ok, []}, fn event, {:ok, processed} ->
      correlation = Map.fetch!(correlations, event.event_key)

      case process_event(receipt, event, correlation) do
        {:ok, persisted} -> {:cont, {:ok, [persisted | processed]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp process_event(receipt, event, correlation) do
    current? = current_event?(event, correlation)

    with {:ok, target} <- resolve_target(receipt.source, event.target_ref),
         {:ok, incident} <- case_for_event(receipt, event, correlation, target, current?),
         {:ok, persisted_event} <- create_event(receipt, event, correlation, incident, target),
         {:ok, incident} <- record_case_input(incident, persisted_event, receipt, event, current?),
         {:ok, _correlation} <-
           update_correlation(correlation, persisted_event, incident, event, current?),
         :ok <- start_resolution(incident, receipt, event, current?) do
      {:ok, persisted_event}
    end
  end

  defp case_for_event(receipt, event, correlation, target, current?) do
    with {:ok, existing} <- existing_case(correlation, receipt.source, event.event_key) do
      cond do
        existing ->
          {:ok, existing}

        current? and event.state == :firing ->
          Cases.open_case(
            :signal,
            receipt.source,
            event.event_key,
            title(event, receipt.source),
            severity(event),
            :firing,
            initial_context(event),
            target && target.id,
            authorize?: false
          )

        true ->
          {:ok, nil}
      end
    end
  end

  defp existing_case(%{case_id: id}, _source, _event_key) when is_binary(id),
    do: Cases.get_case(id, authorize?: false)

  defp existing_case(_correlation, source, event_key) do
    Cases.case_by_trigger(:signal, source, event_key,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp create_event(receipt, event, correlation, incident, target) do
    Cases.create_signal_event_record(
      %{
        signal_receipt_id: receipt.id,
        signal_correlation_id: correlation.id,
        event_key: event.event_key,
        state: event.state,
        source_sequence: sequence(event.source_sequence),
        occurred_at: event.occurred_at,
        target_ref: json_target_ref(event.target_ref),
        attributes: event.attributes,
        metadata: event.metadata,
        case_id: incident && incident.id,
        target_id: target && target.id
      },
      authorize?: false
    )
  end

  defp record_case_input(nil, _persisted_event, _receipt, _event, _current?), do: {:ok, nil}

  defp record_case_input(
         %{status: status} = incident,
         _persisted_event,
         _receipt,
         _event,
         _current?
       )
       when status in [:resolved, :cancelled],
       do: {:ok, incident}

  defp record_case_input(incident, persisted_event, receipt, event, current?) do
    with {:ok, run} <- Cases.active_resolution_run(incident.id, authorize?: false),
         {:ok, _evidence} <-
           create_evidence(incident, run, persisted_event, receipt, event, current?),
         {:ok, incident} <- apply_current_source_state(incident, event, current?) do
      {:ok, incident}
    end
  end

  defp create_evidence(incident, run, persisted_event, receipt, event, current?) do
    key = "signal-event:#{persisted_event.id}"

    with {:ok, evidence} <-
           Cases.create_evidence_record(
             %{
               case_id: incident.id,
               resolution_run_id: run.id,
               idempotency_key: key,
               kind: "signal_event",
               source: receipt.source,
               source_ref: event.event_key,
               content: %{
                 "signal_event_id" => persisted_event.id,
                 "state" => to_string(event.state),
                 "current" => current?,
                 "source_sequence" => sequence(event.source_sequence),
                 "target_ref" => json_target_ref(event.target_ref),
                 "attributes" => event.attributes
               },
               observed_at: event.occurred_at
             },
             authorize?: false
           ),
         {:ok, _event} <-
           Cases.create_case_event_record(
             %{
               case_id: incident.id,
               resolution_run_id: run.id,
               event_type: "signal_event_received",
               idempotency_key: key,
               data: %{
                 "signal_event_id" => persisted_event.id,
                 "evidence_id" => evidence.id,
                 "state" => to_string(event.state),
                 "current" => current?
               }
             },
             authorize?: false
           ) do
      {:ok, evidence}
    end
  end

  defp apply_current_source_state(incident, _event, false), do: {:ok, incident}

  defp apply_current_source_state(%{status: status} = incident, event, true)
       when status in [:running, :needs_attention] do
    cond do
      event.state == :recovered and incident.alert_state == :firing ->
        Cases.record_case_source_recovery(incident.id, incident.revision, authorize?: false)

      event.state == :firing and incident.alert_state == :recovered ->
        mark_source_firing(incident, event)

      true ->
        {:ok, incident}
    end
  end

  defp apply_current_source_state(incident, _event, true), do: {:ok, incident}

  defp mark_source_firing(incident, event) do
    with {:ok, updated} <-
           Cases.update_case_record(
             incident,
             incident.revision,
             %{alert_state: :firing, source_recovered_at: nil},
             authorize?: false
           ),
         {:ok, run} <- Cases.active_resolution_run(incident.id, authorize?: false),
         {:ok, _case_event} <-
           Cases.create_case_event_record(
             %{
               case_id: incident.id,
               resolution_run_id: run.id,
               event_type: "source_firing",
               idempotency_key:
                 "source-firing:#{event.event_key}:#{DateTime.to_iso8601(event.occurred_at)}",
               data: %{"occurred_at" => DateTime.to_iso8601(event.occurred_at)}
             },
             authorize?: false
           ) do
      {:ok, updated}
    end
  end

  defp update_correlation(correlation, persisted_event, incident, event, true) do
    Cases.update_signal_correlation_record(
      correlation,
      correlation.revision,
      %{
        current_state: event.state,
        current_occurred_at: event.occurred_at,
        current_source_sequence: sequence(event.source_sequence),
        latest_signal_event_id: persisted_event.id,
        case_id: incident && incident.id
      },
      authorize?: false
    )
  end

  defp update_correlation(correlation, _persisted_event, incident, _event, false) do
    if is_nil(correlation.case_id) and incident do
      Cases.update_signal_correlation_record(
        correlation,
        correlation.revision,
        %{case_id: incident.id},
        authorize?: false
      )
    else
      {:ok, correlation}
    end
  end

  defp start_resolution(%{status: :running} = incident, receipt, event, true)
       when event.state == :firing do
    with {:ok, run} <- Cases.active_resolution_run(incident.id, authorize?: false),
         {:ok, result} <-
           Cases.start_turn(
             incident.id,
             run.id,
             initial_turn_key(receipt, event),
             %{"objective" => "Resolve the incident"},
             %{"action" => "continue"},
             "Review Resolver limits",
             authorize?: false
           ),
         true <- result.status in [:charged, :duplicate, :exhausted] do
      :ok
    end
  end

  defp start_resolution(_incident, _receipt, _event, _current?), do: :ok

  defp resolve_target(_source, nil), do: {:ok, nil}

  defp resolve_target(source, target_ref) when is_map(target_ref) do
    with {:ok, kind} <- ref_value(target_ref, :kind),
         {:ok, value} <- ref_value(target_ref, :value),
         {:ok, identity} <-
           Targets.resolve_external_identity(source, kind, value,
             authorize?: false,
             not_found_error?: false
           ) do
      {:ok, identity && identity.target}
    else
      :missing -> {:ok, nil}
      {:error, _error} = error -> error
    end
  end

  defp resolve_target(_source, _target_ref), do: {:ok, nil}

  defp ref_value(ref, key) do
    value = Map.get(ref, key) || Map.get(ref, Atom.to_string(key))

    cond do
      is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      is_atom(value) -> {:ok, Atom.to_string(value)}
      true -> :missing
    end
  end

  defp current_event?(_event, %{current_occurred_at: nil}), do: true

  defp current_event?(event, correlation) do
    case DateTime.compare(event.occurred_at, correlation.current_occurred_at) do
      :gt ->
        true

      :lt ->
        false

      :eq ->
        sequence_compare(sequence(event.source_sequence), correlation.current_source_sequence)
    end
  end

  defp sequence_compare(nil, nil), do: true
  defp sequence_compare(nil, _current), do: false
  defp sequence_compare(_incoming, nil), do: true

  defp sequence_compare(incoming, current) do
    case {Integer.parse(incoming), Integer.parse(current)} do
      {{incoming_number, ""}, {current_number, ""}} -> incoming_number >= current_number
      _other -> incoming >= current
    end
  end

  defp existing_receipt(provider_id, receipt_id) do
    Cases.signal_receipt_by_source_identity(provider_id, receipt_id,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp validate_receipt_replay(receipt, result, digest) do
    if receipt.normalized_digest == digest and receipt.source == result.receipt.source and
         receipt.event_count == length(result.events) do
      {:ok, receipt}
    else
      {:error, "Signal receipt identity was reused with different normalized events"}
    end
  end

  defp correlation(provider_id, source, event_key) do
    Cases.signal_correlation_by_source(provider_id, source, event_key,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp title(event, source) do
    case fact(event.attributes, "title") do
      value when is_binary(value) and byte_size(value) > 0 -> String.slice(value, 0, 200)
      _other -> String.slice("#{source}: #{event.event_key}", 0, 200)
    end
  end

  defp severity(event) do
    case fact(event.attributes, "severity") do
      value when value in [:info, :warning, :error, :critical] -> value
      "info" -> :info
      "warning" -> :warning
      "error" -> :error
      "critical" -> :critical
      _other -> :warning
    end
  end

  defp initial_context(event) do
    %{
      "signal_event_key" => event.event_key,
      "target_ref" => json_target_ref(event.target_ref)
    }
  end

  defp json_target_ref(nil), do: nil

  defp json_target_ref(ref) when is_map(ref) do
    Map.new(ref, fn {key, value} -> {to_string(key), value} end)
  end

  defp json_target_ref(_ref), do: nil

  defp fact(facts, key), do: Map.get(facts, key) || Map.get(facts, String.to_existing_atom(key))

  defp sequence(nil), do: nil
  defp sequence(value), do: to_string(value)

  defp initial_turn_key(receipt, event) do
    raw = [receipt.provider_id, receipt.source, event.event_key] |> Enum.join(":")
    "signal-initial:" <> (:crypto.hash(:sha256, raw) |> Base.encode16(case: :lower))
  end

  defp digest(result) do
    binary = :erlang.term_to_binary(result, [:deterministic])

    :crypto.hash(:sha256, binary)
    |> Base.encode16(case: :lower)
  end
end
