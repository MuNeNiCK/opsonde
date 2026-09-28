import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { expect, test } from "vite-plus/test";
import i18n from "@/i18n/config";
import { ProviderSetup } from "@/providers/ai-section";
import type { components } from "@/api/schema";

type Provider = components["schemas"]["Provider"];
type Assignment = components["schemas"]["AIUsageRoleAssignment"];

const provider: Provider = {
  id: "00000000-0000-0000-0000-000000000001",
  name: "Primary AI",
  kind: "ai",
  adapter_type: "req-llm",
  enabled: true,
  revision: 1,
  configuration: { provider: "openai", model: "example-model" },
  check: {
    status: "passed",
    category: null,
    checked_at: "2026-09-29T00:00:00Z",
    checked_revision: 1,
    message: null,
  },
  inserted_at: "2026-09-29T00:00:00Z",
  updated_at: "2026-09-29T00:00:00Z",
};

const assignments: Assignment[] = (["resolver", "reviewer"] as const).map((role, index) => ({
  id: `00000000-0000-0000-0000-00000000000${index + 2}`,
  provider_id: provider.id,
  role,
  enabled: true,
  priority: 100,
  revision: 1,
  inserted_at: "2026-09-29T00:00:00Z",
  updated_at: "2026-09-29T00:00:00Z",
}));

test("warns before the only Reviewer is changed to Resolver in Auto mode", async () => {
  await i18n.changeLanguage("en");
  const user = userEvent.setup();

  render(
    <MemoryRouter>
      <ProviderSetup
        providers={[provider]}
        services={[]}
        assignments={assignments}
        authorityMode="auto"
        canManage
        onRefresh={async () => {}}
        onError={() => {}}
      />
    </MemoryRouter>,
  );

  expect(screen.queryByText(/None is assigned, so changes cannot run automatically/)).toBeNull();

  await user.click(screen.getByRole("button", { name: "Primary AI: Settings" }));
  await user.click(screen.getByRole("combobox", { name: "Use for" }));
  await user.click(screen.getByRole("option", { name: "Resolver" }));

  expect(
    screen.getByText(/Saving this setting leaves no AI assigned to review proposed changes/),
  ).toBeTruthy();
});
