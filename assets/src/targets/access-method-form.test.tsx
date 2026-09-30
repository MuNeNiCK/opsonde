import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { apiClient } from "@/api/client";
import i18n from "@/i18n/config";
import { AccessMethodForm } from "@/targets/access-method-form";
import type { Provider, Target, TargetTypeCatalog } from "@/targets/data";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

test("Method discovery and registration both use the operator's exact endpoint", async () => {
  await i18n.changeLanguage("en");
  const time = "2026-09-30T00:00:00Z";
  const target: Target = {
    id: "target-1",
    name: "edge",
    kind: "network_device",
    type_id: "custom-network-device",
    active: true,
    facts: {},
    operating_instructions: "",
    management_boundary_id: null,
    revision: 1,
    inserted_at: time,
    updated_at: time,
  };
  const provider: Provider = {
    id: "provider-1",
    name: "Shared HTTP credentials",
    kind: "target",
    adapter_type: "http-api",
    access_method_profile: { method: "http" },
    configuration: {},
    enabled: true,
    revision: 3,
    check: {
      status: "passed",
      checked_revision: 3,
      checked_at: time,
      category: null,
      message: null,
    },
    inserted_at: time,
    updated_at: time,
  };
  const catalog: TargetTypeCatalog = {
    categories: [{ id: "network-device", label: "Network device" }],
    types: [
      {
        id: "custom-network-device",
        label: "Custom network device",
        category_id: "network-device",
        kind: "network_device",
        access_method_types: ["http-api"],
      },
    ],
    methods: [{ adapter_type: "http-api", label: "HTTP API", protocol: "http" }],
  };
  const calls: { path: string; options: unknown }[] = [];
  vi.spyOn(apiClient, "POST").mockImplementation(((path: string, options: unknown) => {
    calls.push({ path, options });
    return Promise.resolve({
      data: {
        data: path.endsWith("target-capabilities")
          ? { observations: [{ capability: "request.http.observe" }], effects: [] }
          : { id: "method-1" },
      },
      response: new Response(),
    });
  }) as typeof apiClient.POST);
  const saved = vi.fn(async () => {});
  const error = vi.fn();
  const user = userEvent.setup();
  render(
    <AccessMethodForm
      target={target}
      providers={[provider]}
      catalog={catalog}
      onSaved={saved}
      onError={error}
    />,
  );

  await user.click(screen.getByRole("combobox", { name: "Connection" }));
  await user.click(screen.getByRole("option", { name: "Shared HTTP credentials · http-api" }));
  await user.type(screen.getByRole("textbox", { name: "Name" }), "second device");
  await user.type(screen.getByRole("textbox", { name: "Endpoint" }), "https://second.example");
  await user.click(screen.getByRole("button", { name: "Add access method" }));
  await waitFor(() => expect(saved).toHaveBeenCalledOnce());
  expect(calls).toEqual([
    {
      path: "/api/v1/providers/{id}/target-capabilities",
      options: {
        params: { path: { id: "provider-1" } },
        body: { provider: { expected_revision: 3, endpoint: "https://second.example" } },
      },
    },
    {
      path: "/api/v1/access-methods",
      options: {
        body: {
          access_method: {
            target_id: "target-1",
            provider_id: "provider-1",
            provider_revision: 3,
            method: "http",
            name: "second device",
            endpoint: "https://second.example",
            priority: 100,
            capabilities: ["request.http.observe"],
          },
        },
      },
    },
  ]);
  expect(error).toHaveBeenLastCalledWith("");
});
