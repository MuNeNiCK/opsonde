defmodule Opsonde.Cases.Case.InvocationContext do
  @moduledoc false

  @enforce_keys [
    :case_id,
    :case_revision,
    :resolution_run_id,
    :run_generation,
    :subject,
    :conditions,
    :targets,
    :methods,
    :selection
  ]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  def project(incident, run, subject, conditions, selection, methods) do
    methods =
      methods
      |> Enum.map(
        &Map.take(&1, [
          :target_id,
          :target_revision,
          :access_method_id,
          :access_method_revision,
          :provider_id,
          :provider_revision,
          :capability
        ])
      )
      |> Enum.uniq()

    selected =
      if incident.selected_target_id,
        do: [%{id: incident.selected_target_id, revision: incident.selected_target_revision}],
        else: []

    %__MODULE__{
      case_id: incident.id,
      case_revision: incident.revision,
      resolution_run_id: run.id,
      run_generation: run.generation,
      subject: subject,
      conditions: Opsonde.Cases.Case.ConditionContext.condition_revisions(conditions),
      targets:
        Enum.uniq(
          selected ++ Enum.map(methods, &%{id: &1.target_id, revision: &1.target_revision})
        ),
      methods: methods,
      selection: selection
    }
  end

  def invocation(context, supplied) do
    cancelled = Map.get(supplied, :cancelled?)

    Map.put(supplied, :cancelled?, fn ->
      (is_function(cancelled, 0) and cancelled.()) or
        not Opsonde.Cases.invocation_context_current!(context, authorize?: false)
    end)
  end
end
