import { render, screen, within } from "@testing-library/react";
import { expect, test } from "vite-plus/test";
import type { components } from "@/api/schema";
import { CaseAIUsage } from "@/cases/ai-usage";
import i18n from "@/i18n/config";

test("shows service-reported zero separately from unmeasured calls and budget reservations", async () => {
  await i18n.changeLanguage("en");
  const usage: components["schemas"]["CaseAIUsage"] = {
    reported_input_tokens: 17,
    reported_output_tokens: 9,
    reported_total_tokens: 26,
    reported_invocations: 2,
    unknown_invocations: 1,
    pending_invocations: 0,
    not_dispatched_invocations: 1,
    budget_charged_units: 65562,
    unknown_reserved_units: 65536,
    pending_reserved_units: 0,
    complete: false,
  };
  const common = {
    case_id: "case-1",
    resolution_run_id: "run-1",
    provider_id: "provider-1",
    turn_id: null,
    proposal_id: null,
    role: "resolver" as const,
    status: "failed" as const,
    reserved_units: 65536,
    cached_tokens: null,
    reasoning_tokens: null,
    finish_reason: null,
    dispatch_started_at: "2026-10-02T00:00:00Z",
    completed_at: "2026-10-02T00:00:01Z",
    dispatch_confirmed: true,
  };
  render(
    <CaseAIUsage
      usage={usage}
      invocations={[
        {
          ...common,
          id: "unsent",
          status: "queued",
          usage_status: "not_dispatched",
          dispatch_confirmed: false,
          dispatch_started_at: null,
          completed_at: null,
          input_tokens: null,
          output_tokens: null,
        },
        { ...common, id: "zero", usage_status: "reported", input_tokens: 0, output_tokens: 0 },
        {
          ...common,
          id: "unmeasured",
          usage_status: "unknown",
          input_tokens: null,
          output_tokens: null,
        },
        { ...common, id: "paid", usage_status: "reported", input_tokens: 17, output_tokens: 9 },
      ]}
    />,
  );
  expect(screen.getByText("26")).toBeTruthy();
  expect(screen.getByText("65,562")).toBeTruthy();
  expect(screen.getByText("Incomplete")).toBeTruthy();
  expect(screen.getByText(/Case calls only/)).toBeTruthy();
  const unknown = screen.getByRole("row", { name: /Unmeasured/ });
  expect(within(unknown).getAllByText("Unavailable").length).toBeGreaterThanOrEqual(2);
  expect(within(unknown).queryByText("0")).toBeNull();
  const unsent = screen.getByRole("row", { name: /Awaiting retry/ });
  expect(within(unsent).getByText("Not sent")).toBeTruthy();
  expect(within(unsent).queryByText("0")).toBeNull();
  const rows = screen.getAllByRole("row", { name: /Reported/ });
  expect(within(rows[0]!).getAllByText("0")).toHaveLength(2);
  expect(within(rows[1]!).getByText("17")).toBeTruthy();
  expect(within(rows[1]!).getByText("9")).toBeTruthy();
  expect(within(rows[1]!).getAllByText("Unavailable")).toHaveLength(2);
});
