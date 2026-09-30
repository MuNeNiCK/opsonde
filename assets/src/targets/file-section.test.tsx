import { render, screen, waitFor, cleanup } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import i18n from "@/i18n/config";
import { TargetFileSection } from "@/targets/file-section";
import { CaseCreatePage } from "@/cases/create-page";

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});

test("Case creation refetches a selected ready file and submits its exact reference without bytes", async () => {
  await i18n.changeLanguage("en");
  sessionStorage.setItem("opsonde.session", "fixture-token");
  const reference = {
    id: "file-1",
    target_id: "target-1",
    name: "payload.bin",
    media_type: "application/octet-stream",
    size_bytes: 5,
    sha256: digest,
  };
  let submitted: Record<string, unknown> | undefined;
  wire.mockImplementation(async (request: Request) => {
    const path = new URL(request.url, "http://localhost").pathname;
    if (path === "/api/v1/targets")
      return new Response(
        JSON.stringify({
          data: [{ id: "target-1", name: "device", active: true }],
          page: { next: null },
        }),
      );
    if (path.endsWith("/files"))
      return new Response(
        JSON.stringify({
          data: [{ ...reference, status: "ready", expires_at: "2099-01-01T00:00:00Z" }],
          page: { next: null },
        }),
      );
    if (path.endsWith("/files/file-1"))
      return new Response(
        JSON.stringify({
          data: { ...reference, status: "ready", expires_at: "2099-01-01T00:00:00Z" },
        }),
      );
    if (path === "/api/v1/cases" && request.method === "POST") {
      submitted = (await request.json()).case;
      return new Response(JSON.stringify({ data: { id: "case-1" } }));
    }
    throw Error("Unexpected Case API request");
  });
  render(
    <AuthenticationContext.Provider value={{ account: { role: "operator" } } as Authentication}>
      <MemoryRouter initialEntries={["/cases/new?target=target-1&file=file-1"]}>
        <Routes>
          <Route path="/cases/new" element={<CaseCreatePage />} />
          <Route path="/cases/:id" element={<p>Case created</p>} />
        </Routes>
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  const user = userEvent.setup();
  await screen.findByText("payload.bin");
  await user.type(screen.getByLabelText("Title"), "Apply supplied file");
  await user.type(
    screen.getByLabelText("Desired outcome"),
    "Use the supplied payload to configure the device",
  );
  await user.click(screen.getByRole("button", { name: "Create Case" }));
  await screen.findByText("Case created");
  expect(submitted?.initial_target_id).toBe("target-1");
  expect(submitted?.initial_context).toEqual({
    desired_outcome: "Use the supplied payload to configure the device",
    files: { attachment: reference },
  });
});
const digest = "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd";
afterEach(() => {
  cleanup();
  wire.mockReset();
  vi.restoreAllMocks();
  sessionStorage.clear();
});

test("download requests authenticated binary chunks and refuses corrupt bytes before saving", async () => {
  await i18n.changeLanguage("en");
  sessionStorage.setItem("opsonde.session", "fixture-token");
  const file = {
    id: "file-1",
    target_id: "target-1",
    name: "payload.bin",
    media_type: "application/octet-stream",
    size_bytes: 5,
    received_bytes: 5,
    status: "ready",
    sha256: digest,
    expires_at: "2099-01-01T00:00:00Z",
  };
  let corrupt = false;
  let saved: Blob | undefined;
  const create = vi.spyOn(URL, "createObjectURL").mockImplementation((blob) => {
    saved = blob as Blob;
    return "blob:fixture";
  });
  vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {});
  wire.mockImplementation(async (request: Request) => {
    expect(request.headers.get("Authorization")).toBe("Bearer fixture-token");
    const path = new URL(request.url, "http://localhost").pathname;
    if (path.endsWith("target-file-limits"))
      return new Response(JSON.stringify({ data: { chunk_bytes: 3, max_size_bytes: 10 } }));
    if (path.endsWith("/files"))
      return new Response(JSON.stringify({ data: [file], page: { next: null } }));
    if (path.includes("/chunks/")) {
      expect(request.headers.get("Accept")).toBe("application/octet-stream");
      const offset = Number(path.split("/").at(-1));
      return new Response(new Uint8Array(offset === 0 ? [255, 0, 1] : [2, corrupt ? 0 : 255]));
    }
    return new Response(JSON.stringify({ data: file }));
  });
  render(
    <AuthenticationContext.Provider value={{ account: { role: "operator" } } as Authentication}>
      <MemoryRouter>
        <TargetFileSection targetId="target-1" />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: "Download" }));
  await waitFor(() => expect(create).toHaveBeenCalledTimes(1));
  expect(Array.from(new Uint8Array(await saved!.arrayBuffer()))).toEqual([255, 0, 1, 2, 255]);
  await waitFor(() => expect(screen.queryByRole("status")).toBeNull());
  corrupt = true;
  await user.click(screen.getByRole("button", { name: "Download" }));
  await screen.findByText("File integrity verification failed.");
  expect(create).toHaveBeenCalledTimes(1);
});

test("operator uploads exact binary and can use only its completed reference in a Case", async () => {
  await i18n.changeLanguage("en");
  sessionStorage.setItem("opsonde.session", "fixture-token");
  const bytes: number[] = [];
  let file: Record<string, unknown> | null = null;
  wire.mockImplementation(async (request: Request) => {
    expect(request.headers.get("Authorization")).toBe("Bearer fixture-token");
    const path = new URL(request.url, "http://localhost").pathname;
    const data = (value: unknown, status = 200) =>
      new Response(JSON.stringify({ data: value }), {
        status,
        headers: { "Content-Type": "application/json" },
      });
    if (path.endsWith("target-file-limits"))
      return data({ chunk_bytes: 3, max_size_bytes: 10, lifetime_seconds: 86400 });
    if (path.endsWith("/files") && request.method === "GET")
      return new Response(JSON.stringify({ data: file ? [file] : [], page: { next: null } }));
    if (path.endsWith("/files") && request.method === "POST") {
      const input = (await request.json()).file;
      expect(input.expected_sha256).toBe(digest);
      file = {
        ...input,
        id: "file-1",
        target_id: "target-1",
        request_id: null,
        status: "uploading",
        received_bytes: 0,
        size_bytes: 5,
        sha256: null,
        expires_at: "2099-01-01T00:00:00Z",
      };
      return data(file, 201);
    }
    if (request.method === "PUT") {
      expect(request.headers.get("Content-Type")).toBe("application/octet-stream");
      expect(Number(path.split("/").at(-1))).toBe(bytes.length);
      bytes.push(...new Uint8Array(await request.arrayBuffer()));
      file = { ...file, received_bytes: bytes.length };
      return data(file);
    }
    if (path.endsWith("/complete")) {
      file = { ...file, status: "ready", sha256: digest };
      return data(file);
    }
    if (request.method === "GET") return data(file);
    throw Error("Unexpected file API request");
  });
  render(
    <AuthenticationContext.Provider value={{ account: { role: "operator" } } as Authentication}>
      <MemoryRouter>
        <TargetFileSection targetId="target-1" />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  const user = userEvent.setup();
  await user.upload(
    await screen.findByLabelText("Add file"),
    new File([new Uint8Array([255, 0, 1, 2, 255])], "payload.bin", {
      type: "application/octet-stream",
    }),
  );
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "Use in Case" }).getAttribute("href")).toBe(
      "/cases/new?target=target-1&file=file-1",
    ),
  );
  expect(bytes).toEqual([255, 0, 1, 2, 255]);
  expect(screen.getByText(digest)).toBeTruthy();
});

test("after a lost chunk reply, reloading exposes persisted progress and an explicit resume sends only remaining bytes", async () => {
  await i18n.changeLanguage("en");
  sessionStorage.setItem("opsonde.session", "fixture-token");
  const bytes: number[] = [];
  let file: Record<string, unknown> | null = null;
  let lost = false;
  wire.mockImplementation(async (request: Request) => {
    const path = new URL(request.url, "http://localhost").pathname;
    const data = (value: unknown) => new Response(JSON.stringify({ data: value }));
    if (path.endsWith("target-file-limits")) return data({ chunk_bytes: 3, max_size_bytes: 10 });
    if (path.endsWith("/files") && request.method === "GET")
      return new Response(JSON.stringify({ data: file ? [file] : [], page: { next: null } }));
    if (path.endsWith("/files") && request.method === "POST") {
      file = {
        ...(await request.json()).file,
        id: "file-1",
        target_id: "target-1",
        status: "uploading",
        received_bytes: 0,
        sha256: null,
        expires_at: "2099-01-01T00:00:00Z",
      };
      return data(file);
    }
    if (request.method === "PUT") {
      expect(Number(path.split("/").at(-1))).toBe(bytes.length);
      bytes.push(...new Uint8Array(await request.arrayBuffer()));
      file = { ...file, received_bytes: bytes.length };
      if (!lost) {
        lost = true;
        throw new TypeError("Lost HTTP response");
      }
      return data(file);
    }
    if (path.endsWith("/complete")) {
      file = { ...file, status: "ready", sha256: digest };
      return data(file);
    }
    return data(file);
  });
  const view = () => (
    <AuthenticationContext.Provider value={{ account: { role: "operator" } } as Authentication}>
      <MemoryRouter>
        <TargetFileSection targetId="target-1" />
      </MemoryRouter>
    </AuthenticationContext.Provider>
  );
  const user = userEvent.setup();
  const local = new File([new Uint8Array([255, 0, 1, 2, 255])], "payload.bin", {
    type: "application/octet-stream",
  });
  const first = render(view());
  await user.upload(await screen.findByLabelText("Add file"), local);
  await screen.findByText("File transfer failed. Refresh to check progress before trying again.");
  expect(bytes).toEqual([255, 0, 1]);
  first.unmount();
  render(view());
  await screen.findByText("3 / 5 B · application/octet-stream");
  expect(screen.queryByRole("button", { name: "Use in Case" })).toBeNull();
  await user.click(screen.getByRole("button", { name: "Resume upload" }));
  await user.upload(screen.getByLabelText("Add file"), local);
  await screen.findByText("Ready");
  expect(bytes).toEqual([255, 0, 1, 2, 255]);
});
