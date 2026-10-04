import { useTranslation } from "react-i18next";
import { usePagedData, type PageData } from "@/api/use-paged-data";
import { FormSelect } from "@/components/form-select";
import { PageControls } from "@/components/page-controls";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Alert, AlertDescription } from "@/components/ui/alert";

export function PagedSelect<T extends { id: string; name: string }>({
  id,
  label,
  selected,
  onChange,
  load,
  display,
  placeholder,
  disabled = false,
}: {
  id: string;
  label: string;
  selected: T | null;
  onChange: (item: T | null) => void;
  load: (after: string | undefined, signal: AbortSignal) => Promise<PageData<T>>;
  display?: (item: T) => string;
  placeholder?: string;
  disabled?: boolean;
}) {
  const { t } = useTranslation();
  const page = usePagedData(load);
  const items = [...(page.view?.data ?? [])];
  if (selected && !items.some((item) => item.id === selected.id)) items.push(selected);
  return (
    <div className="space-y-2" role="group" aria-label={label}>
      <Label htmlFor={id}>{label}</Label>
      <FormSelect
        // Reset the Select's item registration when an off-page selection is replaced.
        key={selected?.id ?? ""}
        id={id}
        value={selected?.id ?? ""}
        placeholder={placeholder}
        disabled={disabled || page.pending}
        options={items.map((item) => ({ value: item.id, label: display?.(item) ?? item.name }))}
        onValueChange={(value) => onChange(items.find((item) => item.id === value) ?? null)}
      />
      <PageControls
        index={page.view?.index ?? 0}
        hasNext={!!page.view?.page.next}
        pending={page.pending || disabled}
        previous={page.previous}
        next={page.next}
      />
      {page.error != null && (
        <Alert variant="destructive">
          <AlertDescription>{t("targets.requestFailed")}</AlertDescription>
          <Button
            type="button"
            size="sm"
            variant="outline"
            onClick={() => void page.retry().catch(() => {})}
          >
            {t("common.refresh")}
          </Button>
        </Alert>
      )}
    </div>
  );
}
