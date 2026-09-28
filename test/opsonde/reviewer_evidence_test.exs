defmodule Opsonde.Cases.Evidence.ReviewerEvidenceTest do
  use ExUnit.Case, async: true

  alias Opsonde.Cases.Evidence.ReviewerEvidence, as: ReviewerEvidence

  test "Reviewer projection preserves facts while removing duplicated transport data" do
    facts = %{"stdout" => String.duplicate("service active\n", 1_400), "exit_status" => 0}

    content = %{
      "target_id" => "linux-target",
      "operation" => "linux.service.list",
      "facts" => facts,
      "details" => %{
        "facts" => facts,
        "evidence" => [facts],
        "observed_at" => "2026-09-27T08:00:00Z"
      }
    }

    projected = ReviewerEvidence.project_content(content)

    assert projected["facts"] == facts
    assert projected["target_id"] == "linux-target"
    assert projected["details_compacted"] == true
    refute Map.has_key?(projected, "details")
    assert byte_size(Jason.encode!(projected)) < byte_size(Jason.encode!(content)) / 2
  end

  test "Reviewer projection retains details with unique outcome information" do
    content = %{
      "facts" => %{"status" => "failed"},
      "details" => %{"message" => "permission denied"}
    }

    assert ReviewerEvidence.project_content(content) == content
  end
end
