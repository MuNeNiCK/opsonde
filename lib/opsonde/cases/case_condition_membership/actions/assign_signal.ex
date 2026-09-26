defmodule Opsonde.Cases.CaseConditionMembership.Actions.AssignSignal do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.{Cases, Signals, Targets}

  alias Opsonde.Cases.{
    Case,
    CaseAdmissionLock,
    CaseConditionMembership,
    CaseDispatch,
    ResolutionRun
  }

  @collect_seconds 5
  @max_conditions 32
  @max_graph_nodes 128

  @impl true
  def run(input, _opts, _context) do
    args = input.arguments

    result =
      Ash.transact([Case, ResolutionRun, CaseConditionMembership, CaseDispatch], fn ->
        # A short global admission lock makes first-event Case creation deterministic
        # across application instances. No remote I/O happens while it is held.
        with :ok <- CaseAdmissionLock.acquire(),
             {:ok, condition} <- Signals.get_condition(args.condition_id, authorize?: false),
             true <- condition.state == :firing || {:error, "Condition is not firing"},
             {:ok, existing} <-
               Cases.active_case_condition(condition.id,
                 authorize?: false,
                 not_found_error?: false
               ) do
          case existing do
            %CaseConditionMembership{} = membership ->
              with {:ok, incident} <- Cases.get_case(membership.case_id, authorize?: false) do
                {:ok, %{case: incident, membership: membership}}
              end

            nil ->
              attach_new(condition, args)
          end
        end
      end)

    case result do
      {:ok, {:ok, assigned}} -> {:ok, assigned}
      {:ok, {:error, _error} = failed} -> failed
      other -> other
    end
  end

  defp attach_new(condition, args) do
    with {:ok, candidate} <- candidate(condition, args.received_at),
         {:ok, incident, new?} <- case_for_candidate(candidate, condition, args),
         {:ok, membership} <-
           Cases.attach_case_condition_record(
             %{
               case_id: incident.id,
               condition_id: condition.id,
               attached_at: args.received_at,
               reason: if(new?, do: "initial_signal", else: "bounded_graph_time_locality")
             },
             authorize?: false
           ) do
      {:ok, %{case: incident, membership: membership}}
    end
  end

  defp case_for_candidate({incident, _dispatch}, _condition, _args),
    do: {:ok, incident, false}

  defp case_for_candidate(nil, condition, args) do
    with {:ok, incident} <-
           Cases.open_case(
             :signal,
             args.source,
             condition.id,
             args.title,
             args.severity,
             :firing,
             Map.put(args.initial_context, "initial_condition_id", condition.id),
             condition.target_id,
             nil,
             authorize?: false
           ),
         {:ok, _dispatch} <- create_dispatch(incident, condition, args.received_at) do
      {:ok, incident, true}
    end
  end

  defp create_dispatch(incident, condition, received_at) do
    due_at = DateTime.add(received_at, @collect_seconds, :second)
    state = if incident.status == :running, do: :collecting, else: :disabled

    with {:ok, dispatch} <-
           Cases.create_case_dispatch_record(
             %{
               case_id: incident.id,
               state: state,
               first_received_at: received_at,
               due_at: due_at,
               anchor_target_id: condition.target_id
             },
             authorize?: false
           ) do
      if state == :collecting do
        with {:ok, _job} <-
               %{"case_id" => incident.id}
               |> Opsonde.Cases.CaseDispatchWorker.new(scheduled_at: due_at)
               |> Oban.insert() do
          {:ok, dispatch}
        end
      else
        {:ok, dispatch}
      end
    end
  end

  defp candidate(%{target_id: nil}, _received_at), do: {:ok, nil}

  defp candidate(condition, received_at) do
    with {:ok, target} <- Targets.get_target(condition.target_id, authorize?: false),
         {:ok, local_ids} <- within_two(condition.target_id),
         {:ok, dispatches} <- Cases.admitting_case_dispatches(authorize?: false) do
      dispatches
      |> Enum.find_value(fn dispatch ->
        with true <- DateTime.compare(received_at, dispatch.first_received_at) != :lt,
             true <- DateTime.compare(received_at, dispatch.due_at) == :lt,
             true <- dispatch.anchor_target_id in local_ids,
             {:ok, anchor} <- Targets.get_target(dispatch.anchor_target_id, authorize?: false),
             true <- anchor.management_boundary_id == target.management_boundary_id,
             {:ok, incident} <- Cases.get_case(dispatch.case_id, authorize?: false),
             true <- incident.status in [:running, :needs_attention],
             {:ok, members} <-
               Cases.active_conditions_for_case(incident.id, authorize?: false),
             true <- length(members) < @max_conditions,
             {:ok, conditions} <- member_conditions(members),
             true <- Enum.all?(conditions, &(&1.target_id in local_ids)) do
          {incident, dispatch}
        else
          _other -> nil
        end
      end)
      |> then(&{:ok, &1})
    else
      {:error, :graph_too_large} -> {:ok, nil}
      {:error, _error} = error -> error
    end
  end

  defp member_conditions(members) do
    members
    |> Enum.reduce_while({:ok, []}, fn member, {:ok, conditions} ->
      case Signals.get_condition(member.condition_id, authorize?: false) do
        {:ok, condition} -> {:cont, {:ok, [condition | conditions]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp within_two(target_id) do
    with {:ok, first_edges} <-
           Targets.adjacent_relationships_for_case_admission(target_id, authorize?: false),
         true <- length(first_edges) <= @max_graph_nodes || {:error, :graph_too_large},
         first <- first_edges |> Enum.map(&other_id(&1, target_id)) |> Enum.uniq(),
         true <- length(first) <= @max_graph_nodes || {:error, :graph_too_large} do
      first
      |> Enum.reduce_while({:ok, MapSet.new([target_id | first])}, fn id, {:ok, found} ->
        case Targets.adjacent_relationships_for_case_admission(id, authorize?: false) do
          {:ok, edges} ->
            next = Enum.map(edges, &other_id(&1, id))
            found = Enum.reduce(next, found, &MapSet.put(&2, &1))

            if length(edges) <= @max_graph_nodes and MapSet.size(found) <= @max_graph_nodes,
              do: {:cont, {:ok, found}},
              else: {:halt, {:error, :graph_too_large}}

          {:error, _error} = error ->
            {:halt, error}
        end
      end)
    end
  end

  defp other_id(edge, id) do
    if edge.source_target_id == id, do: edge.destination_target_id, else: edge.source_target_id
  end
end
