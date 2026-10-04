import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";

export function PageControls({
  index,
  hasNext,
  pending,
  previous,
  next,
}: {
  index: number;
  hasNext: boolean;
  pending: boolean;
  previous: () => void;
  next: () => void;
}) {
  const { t } = useTranslation();
  return (
    <div className="flex items-center gap-2 text-sm">
      <Button
        type="button"
        size="sm"
        variant="outline"
        disabled={pending || index === 0}
        onClick={previous}
      >
        {t("common.previousPage")}
      </Button>
      <span>{t("common.pageNumber", { page: index + 1 })}</span>
      <Button
        type="button"
        size="sm"
        variant="outline"
        disabled={pending || !hasNext}
        onClick={next}
      >
        {t("common.nextPage")}
      </Button>
    </div>
  );
}
