import type { TFunction } from "i18next";
import type { components } from "@/api/schema";

export function formValue(form: FormData, name: string) {
  const value = form.get(name);
  return typeof value === "string" ? value : "";
}

export function parseAuthorityMode(value: string): components["schemas"]["Case"]["authority_mode"] {
  return value === "readonly" || value === "ask" || value === "auto" || value === "full_access"
    ? value
    : "readonly";
}

export function translatedToken(t: TFunction, group: string, value: string) {
  return t("cases." + group + "." + value, { defaultValue: humanize(value) });
}

export function summarizeValue(value: unknown, fallback: string): string {
  if (value === null || value === undefined || value === "") return fallback;
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  if (Array.isArray(value)) {
    return value.map((item) => summarizeValue(item, fallback)).join(", ");
  }
  if (typeof value !== "object") return fallback;

  const record = value as Record<string, unknown>;
  for (const key of [
    "summary",
    "message",
    "reason",
    "outcome",
    "status",
    "intent",
    "observation",
  ]) {
    if (record[key] !== undefined) return summarizeValue(record[key], fallback);
  }

  const entries = Object.entries(record).slice(0, 3);
  return entries.length === 0
    ? fallback
    : entries
        .map(([key, item]) => humanize(key) + ": " + summarizeValue(item, fallback))
        .join(" · ");
}

function humanize(value: string) {
  return value.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

export function formatDate(value: string, locale = "en") {
  return new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" }).format(
    new Date(value),
  );
}
