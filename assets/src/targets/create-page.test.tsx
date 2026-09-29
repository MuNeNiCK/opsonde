import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { apiClient } from "@/api/client";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import i18n from "@/i18n/config";
import { TargetCreatePage } from "@/targets/create-page";

afterEach(() => vi.restoreAllMocks());

test("lists published types, filters categories, and creates the selected type", async () => {
  await i18n.changeLanguage("en");
  const user = userEvent.setup();
  const requests: unknown[] = [];

  vi.spyOn(apiClient, "GET").mockImplementation(((path: string) =>
    Promise.resolve({
      data:
        path === "/api/v1/target-types"
          ? {
              data: {
                categories: [
                  { id: "os", label: "Operating system" },
                  { id: "network-device", label: "Network device" },
                  { id: "storage", label: "Storage" },
                ],
                types: [
                  {
                    id: "linux",
                    label: "Linux",
                    kind: "host",
                    category_id: "os",
                    access_method_types: ["linux-ssh"],
                  },
                  {
                    id: "custom-network-device",
                    label: "Custom network device",
                    kind: "network_device",
                    category_id: "network-device",
                    access_method_types: ["ssh"],
                  },
                ],
              },
            }
          : { data: [], page: { next: null } },
      response: new Response(),
    })) as typeof apiClient.GET);

  vi.spyOn(apiClient, "POST").mockImplementation(((path: string, options: unknown) => {
    requests.push({ path, options });
    return Promise.resolve({ data: { data: { id: "target-1" } }, response: new Response() });
  }) as typeof apiClient.POST);

  render(
    <AuthenticationContext.Provider value={{ account: { role: "admin" } } as Authentication}>
      <MemoryRouter initialEntries={["/targets/new"]}>
        <Routes>
          <Route path="/targets/new" element={<TargetCreatePage />} />
          <Route path="/targets/new/:targetType" element={<TargetCreatePage />} />
          <Route path="/targets/:targetId" element={<p>Target saved</p>} />
        </Routes>
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );

  expect(await screen.findByText("Linux")).toBeTruthy();
  expect(screen.getByText("Custom network device")).toBeTruthy();
  expect(screen.getByRole("combobox", { name: "Filter by category" })).toBeTruthy();

  await user.click(screen.getByRole("combobox", { name: "Filter by category" }));
  await user.click(screen.getByRole("option", { name: "Network device" }));
  expect(screen.queryByText("Linux")).toBeNull();
  expect(screen.getByText("Custom network device")).toBeTruthy();

  await user.click(screen.getByText("Custom network device"));
  await user.type(screen.getByRole("textbox", { name: "Name" }), "edge-1");
  await user.click(screen.getByRole("button", { name: "Add Target" }));

  await waitFor(() => expect(screen.getByText("Target saved")).toBeTruthy());
  expect(requests).toEqual([
    {
      path: "/api/v1/targets",
      options: {
        body: {
          target: {
            name: "edge-1",
            kind: "network_device",
            type_id: "custom-network-device",
            facts: {},
            management_boundary_id: null,
          },
        },
      },
    },
  ]);
});
