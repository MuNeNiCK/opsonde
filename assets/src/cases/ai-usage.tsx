import { useTranslation } from "react-i18next";
import type { components } from "@/api/schema";
import { Badge } from "@/components/ui/badge";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

type Props = {
  usage: components["schemas"]["CaseAIUsage"];
  invocations: components["schemas"]["AIInvocation"][];
};

export function CaseAIUsage({ usage, invocations }: Props) {
  const { t, i18n } = useTranslation();
  const number = (value: number) => value.toLocaleString(i18n.language);
  const tokens = (value: number | null) =>
    value === null ? t("cases.aiUsage.unavailable") : number(value);
  const figures = [
    ["reported", usage.reported_total_tokens],
    ["unknown", usage.unknown_invocations],
    ["pending", usage.pending_invocations],
    ["budget", usage.budget_charged_units],
  ] as const;

  return (
    <details className="border-t pt-4">
      <summary className="cursor-pointer font-medium">
        <span>{t("cases.aiUsage.title")}</span>
        <Badge variant="outline" className="ml-2">
          {t(`cases.aiUsage.${usage.complete ? "complete" : "incomplete"}`)}
        </Badge>
      </summary>
      <div className="mt-4 space-y-4">
        <dl className="grid grid-cols-2 gap-4 lg:grid-cols-4">
          {figures.map(([label, value]) => (
            <div key={label}>
              <dt className="text-xs text-muted-foreground">{t(`cases.aiUsage.${label}`)}</dt>
              <dd className="mt-1 text-lg font-semibold tabular-nums">{number(value)}</dd>
            </div>
          ))}
        </dl>
        {usage.unknown_invocations > 0 && (
          <p className="text-sm text-muted-foreground">
            {t("cases.aiUsage.unknownReservation", { units: number(usage.unknown_reserved_units) })}
          </p>
        )}
        {usage.pending_invocations > 0 && (
          <p className="text-sm text-muted-foreground">
            {t("cases.aiUsage.pendingReservation", { units: number(usage.pending_reserved_units) })}
          </p>
        )}
        <p className="text-xs text-muted-foreground">{t("cases.aiUsage.scope")}</p>
        {invocations.length > 0 && (
          <details>
            <summary className="cursor-pointer text-sm font-medium">
              {t("cases.aiUsage.history")}
            </summary>
            <div className="mt-3 overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    {[
                      "role",
                      "result",
                      "measurement",
                      "input",
                      "output",
                      "cache",
                      "reasoning",
                      "reserved",
                    ].map((label) => (
                      <TableHead key={label}>{t(`cases.aiUsage.${label}`)}</TableHead>
                    ))}
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {invocations.map((invocation) => (
                    <TableRow key={invocation.id}>
                      <TableCell>
                        {invocation.role === "resolver" ? "Resolver" : "Reviewer"}
                      </TableCell>
                      <TableCell>{t(`cases.aiUsage.resultStatus.${invocation.status}`)}</TableCell>
                      <TableCell>
                        {t(`cases.aiUsage.usageStatus.${invocation.usage_status}`)}
                      </TableCell>
                      <TableCell>{tokens(invocation.input_tokens)}</TableCell>
                      <TableCell>{tokens(invocation.output_tokens)}</TableCell>
                      <TableCell>{tokens(invocation.cached_tokens)}</TableCell>
                      <TableCell>{tokens(invocation.reasoning_tokens)}</TableCell>
                      <TableCell>{number(invocation.reserved_units)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          </details>
        )}
      </div>
    </details>
  );
}
