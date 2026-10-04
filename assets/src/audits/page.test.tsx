import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import i18n from "@/i18n/config";
import { AuditPage } from "@/audits/page";

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  wire.mockReset();
});

test("the actual Audit form sends its chosen registration identity and selected Target scope", async () => {
  await i18n.changeLanguage("en");
  const id = "20000000-0000-4000-8000-000000000055";
  const targetId = "20000000-0000-4000-8000-000000000056";
  vi.spyOn(crypto, "randomUUID").mockReturnValue(id);
  const posts: Record<string, unknown>[] = [];

  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      expect(url.pathname).toBe("/api/v1/audit-schedules");
      posts.push(await request.json());
      return Response.json({ data: { id } }, { status: 201 });
    }
    return Response.json({
      data:
        url.pathname === "/api/v1/targets"
          ? [{ id: targetId, name: "Selected Linux", active: true }]
          : [],
      page: { next: null },
    });
  });

  render(
    <AuthenticationContext.Provider
      value={{ account: { id: "audit-admin", role: "admin" } } as Authentication}
    >
      <MemoryRouter>
        <AuditPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );

  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Add audit schedule" }));
  await user.type(screen.getByLabelText("Name"), "Daily host audit");
  await user.type(
    screen.getByLabelText("Desired outcome (observable state)"),
    "Storage health is normal",
  );
  await user.click(screen.getByRole("combobox", { name: "Targets" }));
  await user.click(await screen.findByRole("option", { name: "Selected Linux" }));
  await user.keyboard("{Escape}");
  await user.click(screen.getByRole("button", { name: "Create schedule" }));

  await waitFor(() => expect(posts).toHaveLength(1));
  expect(posts[0]).toEqual({
    audit_schedule: {
      registration_id: id,
      name: "Daily host audit",
      desired_outcome: "Storage health is normal",
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      cron_expression: "0 * * * *",
      report_language: "en",
      target_ids: [targetId],
      management_boundary_id: null,
    },
  });
  await waitFor(() => expect(screen.queryByRole("button", { name: "Create schedule" })).toBeNull());
});
