import type { ReactNode } from "react";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { cn } from "@/lib/utils";

export type FormSelectOption = {
  value: string;
  label: ReactNode;
  disabled?: boolean;
};

type CommonProps = {
  id: string;
  name?: string;
  options: FormSelectOption[];
  placeholder?: ReactNode;
  required?: boolean;
  disabled?: boolean;
  className?: string;
  ariaLabel?: string;
};

type FormSelectProps = CommonProps & {
  value?: string | null;
  defaultValue?: string | null;
  onValueChange?: (value: string | null) => void;
};

export function FormSelect({
  id,
  name,
  options,
  placeholder,
  required,
  disabled,
  className,
  ariaLabel,
  value,
  defaultValue,
  onValueChange,
}: FormSelectProps) {
  return (
    <Select
      name={name}
      items={options}
      value={value}
      defaultValue={defaultValue}
      onValueChange={onValueChange}
      required={required}
      disabled={disabled}
    >
      <SelectTrigger id={id} className={cn("w-full", className)} aria-label={ariaLabel}>
        <SelectValue placeholder={placeholder} />
      </SelectTrigger>
      <SelectContent>
        {options.map((option) => (
          <SelectItem key={option.value} value={option.value} disabled={option.disabled}>
            {option.label}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}

type FormMultiSelectProps = CommonProps & {
  value?: string[];
  defaultValue?: string[];
  onValueChange?: (value: string[]) => void;
};

export function FormMultiSelect({
  id,
  name,
  options,
  placeholder,
  required,
  disabled,
  className,
  ariaLabel,
  value,
  defaultValue,
  onValueChange,
}: FormMultiSelectProps) {
  return (
    <Select
      multiple
      name={name}
      items={options}
      value={value}
      defaultValue={defaultValue}
      onValueChange={onValueChange}
      required={required}
      disabled={disabled}
    >
      <SelectTrigger id={id} className={cn("w-full", className)} aria-label={ariaLabel}>
        <SelectValue placeholder={placeholder} />
      </SelectTrigger>
      <SelectContent>
        {options.map((option) => (
          <SelectItem key={option.value} value={option.value} disabled={option.disabled}>
            {option.label}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}
