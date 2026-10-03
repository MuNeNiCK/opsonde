defmodule Opsonde.Cases.Evidence.Calculations.Content do
  use Ash.Resource.Calculation

  require Ash.Query

  alias Opsonde.Cases
  alias Opsonde.Cases.{Operation, VerificationAttempt}

  @impl true
  def load(_query, _opts, _context),
    do: [:case_id, :resolution_run_id, :kind, :source, :source_ref, :stored_content, :observed_at]

  @impl true
  def calculate(records, _opts, context) do
    with {:ok, operations} <- sources(records, Operation, context),
         {:ok, verifications} <- sources(records, VerificationAttempt, context) do
      Enum.reduce_while(records, {:ok, []}, fn record, {:ok, contents} ->
        case content(record, operations, verifications) do
          {:ok, content} -> {:cont, {:ok, [content | contents]}}
          {:error, _error} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, contents} -> {:ok, Enum.reverse(contents)}
        error -> error
      end
    end
  end

  defp sources(records, resource, context) do
    ids = for record <- records, canonical_source(record) == resource, do: record.source_ref

    if ids == [] do
      {:ok, %{}}
    else
      query = Ash.Query.filter(resource, id in ^Enum.uniq(ids))
      opts = [query: query, actor: context.actor, authorize?: context.authorize?]

      result =
        case resource do
          Operation -> Cases.list_operations(Keyword.put(opts, :load, [:proposal]))
          VerificationAttempt -> Cases.list_verification_attempts(opts)
        end

      case result do
        {:ok, sources} -> {:ok, Map.new(sources, &{&1.id, &1})}
        error -> error
      end
    end
  end

  defp content(evidence, operations, verifications) do
    case canonical_source(evidence) do
      Operation ->
        operation_content(evidence, Map.get(operations, evidence.source_ref))

      VerificationAttempt ->
        verification_content(evidence, Map.get(verifications, evidence.source_ref))

      nil ->
        {:ok, evidence.stored_content}
    end
  end

  defp operation_content(evidence, source) do
    with %Operation{} = operation <- source,
         true <- bound?(evidence, operation),
         true <- operation.status in [:applied, :failed, :partial, :unknown],
         true <- evidence.observed_at == operation.completed_at,
         true <- evidence.kind == operation_kind(operation) do
      {facts, details} = Map.pop(operation.result_details, "facts")

      {facts, details} =
        if operation.purpose == :investigation and operation.request_kind == :effect and
             is_nil(facts),
           do: {details, %{}},
           else: {facts || %{}, details}

      {:ok,
       %{
         "status" => to_string(operation.status),
         "category" => operation.outcome_category,
         "reference" => operation.reference,
         "request_kind" => to_string(operation.request_kind),
         "purpose" => to_string(operation.purpose),
         "capability" => operation.capability,
         "operation" => operation.operation,
         "selectors" => operation.selectors,
         "parameters" => operation.parameters,
         "details" => details,
         "facts" => facts,
         "tool_id" => operation.proposal.tool_id,
         "target_id" => operation.target_id,
         "access_method_id" => operation.access_method_id,
         "access_method_revision" => operation.access_method_revision
       }}
    else
      _invalid -> invalid_source("Evidence has no matching terminal Operation receipt")
    end
  end

  defp verification_content(evidence, source) do
    with %VerificationAttempt{} = attempt <- source,
         true <- bound?(evidence, attempt),
         true <- attempt.status in [:verified, :not_verified, :unknown],
         true <- evidence.observed_at == attempt.observed_at,
         true <- evidence.kind == "target_verification" do
      {:ok,
       %{
         "status" => to_string(attempt.status),
         "category" => attempt.outcome_category,
         "facts" => attempt.facts,
         "provider_evidence" => attempt.provider_evidence,
         "expected" => attempt.expected,
         "operation_id" => attempt.operation_id,
         "target_id" => attempt.target_id,
         "access_method_id" => attempt.access_method_id
       }}
    else
      _invalid -> invalid_source("Evidence has no matching terminal Verification receipt")
    end
  end

  defp canonical_source(%{source: "operation", kind: kind})
       when kind in ["observation", "operation_outcome"], do: Operation

  defp canonical_source(%{source: "verification", kind: "target_verification"}),
    do: VerificationAttempt

  defp canonical_source(_evidence), do: nil

  defp invalid_source(message) do
    {:error, Ash.Error.Changes.InvalidAttribute.exception(field: :source_ref, message: message)}
  end

  defp bound?(evidence, source) do
    evidence.case_id == source.case_id and
      evidence.resolution_run_id == source.resolution_run_id and
      evidence.stored_content["target_id"] == source.target_id
  end

  defp operation_kind(%{purpose: :investigation}), do: "observation"
  defp operation_kind(%{purpose: :remediation}), do: "operation_outcome"
end
