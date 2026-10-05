import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import { AIProviderPage, SignalProviderPage } from "@/providers/pages";
import { OnboardingPage } from "@/settings/onboarding-page";
import i18n from "@/i18n/config";

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});
afterEach(() => {
  cleanup();
  wire.mockReset();
});
const id = (n: number) => `10000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const metadata = (n: number, kind = "ai") => ({
  id: id(n),
  name: `Connection ${n}`,
  kind,
  adapter_type: kind === "ai" ? "req-llm" : "alertmanager-webhook",
  enabled: true,
  revision: 1,
  ai_service: "openai",
  ai_model: "example-model",
  check: { status: "passed", checked_revision: 1, checked_at: null, category: null, message: null },
});
const readiness = {
  ai: true,
  resolver: true,
  reviewer: true,
  authority: true,
  signal: true,
  target: true,
  complete: true,
  authority_mode: "auto",
  sole_reviewer_provider_id: id(51),
  first_target_id: id(100),
};
const page = (data: unknown[], next: string | null = null) =>
  Response.json({ data, page: { next } });
function show(kind = "ai", role = "admin") {
  return render(
    <AuthenticationContext.Provider
      value={{ account: { id: "account-1", role, role_version: 1 } } as Authentication}
    >
      <MemoryRouter initialEntries={[kind === "ai" ? "/ai" : "/signals"]}>
        {kind === "ai" ? <AIProviderPage /> : <SignalProviderPage />}
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
}

test("AI pages keep fifty metadata cards, use global Reviewer facts and fetch only the selected configuration", async () => {
  await i18n.changeLanguage("en");
  const requests: URL[] = [];
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    requests.push(url);
    if (url.pathname === "/api/v1/authority-setting/readiness")
      return Promise.resolve(Response.json({ data: readiness }));
    if (url.pathname === "/api/v1/ai-services")
      return Promise.resolve(
        Response.json({
          data: [
            {
              id: "openai",
              name: "OpenAI",
              auth: "api_key",
              endpoint_required: false,
              configuration_fields: [],
            },
          ],
        }),
      );
    if (url.pathname === "/api/v1/providers/summaries")
      return Promise.resolve(
        url.searchParams.has("after")
          ? page([metadata(51)])
          : page(
              Array.from({ length: 50 }, (_, n) => metadata(n + 1)),
              "ai-cursor",
            ),
      );
    if (url.pathname === "/api/v1/ai-usage-role-assignments") {
      const ids = url.searchParams.get("provider_ids")!.split(",");
      return Promise.resolve(
        page(
          ids.map((provider_id) => ({
            id: provider_id,
            provider_id,
            role: provider_id === id(51) ? "reviewer" : "resolver",
            enabled: true,
            priority: 100,
            revision: 1,
            inserted_at: "2026-10-05T00:00:00Z",
            updated_at: "2026-10-05T00:00:00Z",
          })),
        ),
      );
    }
    if (url.pathname === `/api/v1/providers/${id(51)}`)
      return Promise.resolve(
        Response.json({
          data: {
            ...metadata(51),
            configuration: {
              provider: "openai",
              model: "example-model",
              endpoint: "https://api.example/v1",
            },
            inserted_at: "2026-10-05T00:00:00Z",
            updated_at: "2026-10-05T00:00:00Z",
          },
        }),
      );
    throw new Error(`Unexpected request ${url}`);
  });
  show();
  await screen.findByText("Connection 50");
  expect(screen.queryByText("Connection 51")).toBeNull();
  expect(screen.queryByText(/None is assigned, so changes cannot run automatically/)).toBeNull();
  expect(requests.filter((url) => url.pathname === "/api/v1/providers/summaries")).toHaveLength(1);
  expect(
    requests
      .find((url) => url.pathname === "/api/v1/ai-usage-role-assignments")!
      .searchParams.get("provider_ids")!
      .split(","),
  ).toHaveLength(50);
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Next" }));
  await screen.findByText("Connection 51");
  expect(screen.queryByText("Connection 50")).toBeNull();
  await user.click(screen.getByRole("button", { name: "Connection 51: Settings" }));
  await user.click(screen.getByRole("button", { name: i18n.t("setup.edit") }));
  await waitFor(() =>
    expect(screen.getByLabelText("Model")).toHaveProperty("value", "example-model"),
  );
  expect(requests.filter((url) => url.pathname === `/api/v1/providers/${id(51)}`)).toHaveLength(1);
  expect(
    requests.some((url) =>
      [
        "/api/v1/providers",
        "/api/v1/targets",
        "/api/v1/access-methods",
        "/api/v1/authority-setting",
      ].includes(url.pathname),
    ),
  ).toBe(false);
});

test("Signal changes refresh the current window and HTTP failure never repeats a write", async () => {
  await i18n.changeLanguage("en");
  const reads: URL[] = [];
  let posts = 0;
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      posts++;
      return Promise.resolve(
        Response.json({ error: { code: "internal_error" } }, { status: posts === 1 ? 503 : 200 }),
      );
    }
    reads.push(url);
    if (url.pathname === "/api/v1/authority-setting/readiness")
      return Promise.resolve(Response.json({ data: readiness }));
    if (url.pathname === "/api/v1/providers/summaries")
      return Promise.resolve(
        url.searchParams.has("after")
          ? page([metadata(51, "signal")])
          : page([metadata(1, "signal")], "signal-cursor"),
      );
    throw new Error(`Unexpected request ${url}`);
  });
  show("signal");
  await screen.findByText("Connection 1");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Next" }));
  await screen.findByText("Connection 51");
  await user.click(screen.getByRole("button", { name: "Check" }));
  await screen.findByText(i18n.t("cases.requestFailed"));
  expect(posts).toBe(1);
  expect(reads.filter((url) => url.pathname === "/api/v1/providers/summaries")).toHaveLength(2);
  await user.click(screen.getByRole("button", { name: "Check" }));
  await waitFor(() =>
    expect(reads.filter((url) => url.pathname === "/api/v1/providers/summaries")).toHaveLength(3),
  );
  expect(posts).toBe(2);
  expect(
    reads
      .filter((url) => url.pathname === "/api/v1/providers/summaries")
      .at(-1)!
      .searchParams.get("after"),
  ).toBe("signal-cursor");
  expect(reads.every((url) => url.pathname !== "/api/v1/ai-usage-role-assignments")).toBe(true);
  expect(screen.queryByText("Connection 1")).toBeNull();
});

test("required readiness failure stays visible and readonly refresh retries without a write", async () => {
  await i18n.changeLanguage("en");
  let attempts = 0;
  const methods: string[] = [];
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    methods.push(request.method);
    if (url.pathname === "/api/v1/authority-setting/readiness") {
      attempts++;
      return Promise.resolve(
        attempts === 1
          ? Response.json({ error: { code: "internal_error" } }, { status: 500 })
          : Response.json({ data: readiness }),
      );
    }
    return Promise.resolve(page([metadata(51, "signal")]));
  });
  show("signal", "viewer");
  await screen.findByText(i18n.t("setup.requestFailed"));
  expect(screen.queryByText("Connection 51")).toBeNull();
  await userEvent.setup().click(screen.getByRole("button", { name: "Refresh" }));
  await screen.findByText("Connection 51");
  expect(screen.queryByRole("button", { name: "Check" })).toBeNull();
  expect(methods.every((method) => method === "GET")).toBe(true);
});

test("account changes abort the prior Provider page and discard late results", async () => {
  await i18n.changeLanguage("en");
  let first: (value: Response) => void = () => {};
  let oldSignal: AbortSignal | undefined;
  let pages = 0;
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/authority-setting/readiness")
      return Promise.resolve(Response.json({ data: readiness }));
    pages++;
    if (pages === 1) {
      oldSignal = request.signal;
      return new Promise<Response>((resolve) => {
        first = resolve;
      });
    }
    return Promise.resolve(page([metadata(2, "signal")]));
  });
  const view = show("signal");
  await waitFor(() => expect(pages).toBe(1));
  view.rerender(
    <AuthenticationContext.Provider
      value={
        { account: { id: "different-account", role: "viewer", role_version: 1 } } as Authentication
      }
    >
      <MemoryRouter>
        <SignalProviderPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  await screen.findByText("Connection 2");
  expect(oldSignal!.aborted).toBe(true);
  first(page([metadata(1, "signal")]));
  await waitFor(() => expect(screen.queryByText("Connection 1")).toBeNull());
  expect(screen.queryByRole("button", { name: "Check" })).toBeNull();
});

test("onboarding uses only server readiness and sends the operator to the returned Target", async () => {
  await i18n.changeLanguage("en");
  const requests: URL[] = [];
  wire.mockImplementation((request: Request) => {
    requests.push(new URL(request.url));
    return Promise.resolve(
      Response.json({ data: { ...readiness, target: false, complete: false } }),
    );
  });
  render(
    <AuthenticationContext.Provider
      value={{ account: { id: "account-1", role: "admin", role_version: 1 } } as Authentication}
    >
      <MemoryRouter>
        <OnboardingPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  await screen.findByRole("button", { name: i18n.t("onboarding.steps.target.action") });
  expect(
    screen
      .getByRole("button", { name: i18n.t("onboarding.steps.target.action") })
      .getAttribute("href"),
  ).toBe(`/targets/${id(100)}`);
  expect(requests.map((url) => url.pathname)).toEqual(["/api/v1/authority-setting/readiness"]);
});

test("a selected AI detail with a changed revision cannot populate an editing form", async () => {
  await i18n.changeLanguage("en");
  let details = 0;
  let metadataRevision = 1;
  const writes: string[] = [];
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    if (request.method !== "GET") writes.push(request.method);
    if (url.pathname === "/api/v1/authority-setting/readiness")
      return Promise.resolve(Response.json({ data: readiness }));
    if (url.pathname === "/api/v1/ai-services")
      return Promise.resolve(
        Response.json({
          data: [
            {
              id: "openai",
              name: "OpenAI",
              auth: "api_key",
              endpoint_required: false,
              configuration_fields: [],
            },
          ],
        }),
      );
    if (url.pathname === "/api/v1/providers/summaries")
      return Promise.resolve(
        page([
          {
            ...metadata(51),
            revision: metadataRevision,
            check: { ...metadata(51).check, checked_revision: metadataRevision },
          },
        ]),
      );
    if (url.pathname === "/api/v1/ai-usage-role-assignments") return Promise.resolve(page([]));
    if (url.pathname === `/api/v1/providers/${id(51)}`) {
      details++;
      return Promise.resolve(
        Response.json({
          data: {
            ...metadata(51),
            revision: 2,
            configuration: { provider: "openai", model: "changed-model" },
            inserted_at: "2026-10-05T00:00:00Z",
            updated_at: "2026-10-05T00:00:00Z",
          },
        }),
      );
    }
    throw new Error(`Unexpected request ${url}`);
  });
  show();
  await screen.findByText("Connection 51");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Connection 51: Settings" }));
  await user.click(screen.getByRole("button", { name: i18n.t("setup.edit") }));
  await screen.findByText(i18n.t("setup.requestFailed"));
  expect(screen.queryByLabelText("Model")).toBeNull();
  metadataRevision = 2;
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await waitFor(() =>
    expect(screen.getByLabelText("Model")).toHaveProperty("value", "changed-model"),
  );
  expect(details).toBe(2);
  expect(writes).toEqual([]);
  await user.click(screen.getByRole("button", { name: "Cancel" }));
  expect(screen.queryByLabelText("Model")).toBeNull();
});
