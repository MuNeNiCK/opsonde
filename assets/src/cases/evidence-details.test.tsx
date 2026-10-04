import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { EvidenceDetails } from "@/cases/detail-components";
import i18n from "@/i18n/config";

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});

afterEach(() => {
  cleanup();
  wire.mockReset();
  sessionStorage.clear();
});

test("loads exact evidence only when opened and releases it when closed", async () => {
  await i18n.changeLanguage("en");
  sessionStorage.setItem("opsonde.session", "fixture-token");
  const payload = "[REDACTED]".repeat(65_522);
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    expect(new URL(request.url, "http://localhost").pathname).toBe("/api/v1/evidence/receipt-1");
    expect(request.headers.get("Authorization")).toBe("Bearer fixture-token");
    return new Response(JSON.stringify({ data: { content: { details: { payload } } } }));
  });
  render(<EvidenceDetails id="receipt-1" />);
  expect(wire).not.toHaveBeenCalled();
  const user = userEvent.setup();
  const toggle = screen.getByText("Show technical details");
  await user.click(toggle);
  await waitFor(() => expect(document.querySelector("pre")?.textContent).toContain(payload));
  expect(wire).toHaveBeenCalledTimes(1);
  await user.click(toggle);
  await waitFor(() => expect(document.querySelector("pre")).toBeNull());
  await user.click(toggle);
  await waitFor(() => expect(wire).toHaveBeenCalledTimes(2));
});

test("shows a failed read without sending a write or automatically retrying", async () => {
  await i18n.changeLanguage("en");
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    return new Response(JSON.stringify({ error: { message: "Evidence storage unavailable" } }), {
      status: 500,
    });
  });
  render(<EvidenceDetails id="receipt-1" />);
  await userEvent.setup().click(screen.getByText("Show technical details"));
  expect((await screen.findByRole("alert")).textContent).toBe("Evidence storage unavailable");
  expect(wire).toHaveBeenCalledTimes(1);
  expect(document.querySelector("pre")).toBeNull();
});

test("closing a pending read aborts it and a later response cannot populate the reopened row", async () => {
  await i18n.changeLanguage("en");
  let pending: Request | undefined;
  let finish: ((value: Response) => void) | undefined;
  wire.mockImplementationOnce((request: Request) => {
    pending = request;
    return new Promise<Response>((resolve) => {
      finish = resolve;
    });
  });
  wire.mockResolvedValue(
    new Response(JSON.stringify({ data: { content: { message: "fresh receipt" } } })),
  );
  render(<EvidenceDetails id="receipt-1" />);
  const user = userEvent.setup();
  const toggle = screen.getByText("Show technical details");
  await user.click(toggle);
  await waitFor(() => expect(pending).toBeDefined());
  await user.click(toggle);
  await waitFor(() => expect(pending?.signal.aborted).toBe(true));
  await user.click(toggle);
  await screen.findByText(/fresh receipt/);
  finish?.(new Response(JSON.stringify({ data: { content: { message: "stale receipt" } } })));
  await waitFor(() => expect(wire).toHaveBeenCalledTimes(2));
  expect(screen.queryByText(/stale receipt/)).toBeNull();
});
