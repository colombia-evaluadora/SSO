import { useState, type FormEvent, type ReactNode } from "react";
import { Button } from "@/components/ui/Button";
import { useToast } from "@/components/ui/Toast";
import { ApiError } from "@/api/client";

/**
 * Thin form wrapper. Owns:
 *  - submission state (loading)
 *  - error -> toast (so the page doesn't have to render it)
 *  - field-level errors from a Zod parse (mapped via the
 *    {@link fieldErrors} callback)
 *
 * Submits the parsed (typed) values to {@link onSubmit}. The page
 * is responsible for wiring onSubmit to a TanStack Query mutation.
 */
export interface FormProps<TValues> {
  initialValues: TValues;
  validate?: (values: TValues) => Record<string, string>;
  onSubmit: (values: TValues) => Promise<void>;
  onCancel?: () => void;
  submitLabel?: string;
  children: (ctx: {
    values: TValues;
    setField: <K extends keyof TValues>(key: K, value: TValues[K]) => void;
    errors: Record<string, string>;
  }) => ReactNode;
}

export function Form<TValues>({
  initialValues,
  validate,
  onSubmit,
  onCancel,
  submitLabel = "Guardar",
  children,
}: FormProps<TValues>) {
  const [values, setValues] = useState<TValues>(initialValues);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [submitting, setSubmitting] = useState(false);
  const toast = useToast();

  function setField<K extends keyof TValues>(key: K, value: TValues[K]) {
    setValues((prev) => ({ ...prev, [key]: value }));
    setErrors((prev) => {
      if (!(key in prev)) return prev;
      const { [key as string]: _drop, ...rest } = prev;
      return rest;
    });
  }

  async function handleSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const fieldErrors = validate ? validate(values) : {};
    if (Object.keys(fieldErrors).length > 0) {
      setErrors(fieldErrors);
      return;
    }
    setSubmitting(true);
    try {
      await onSubmit(values);
    } catch (err) {
      const msg =
        err instanceof ApiError
          ? `${err.code}: ${err.message}`
          : err instanceof Error
            ? err.message
            : "Error desconocido";
      toast.show(msg, "error");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} noValidate className="flex flex-col gap-4">
      {children({ values, setField, errors })}
      <div className="flex justify-end gap-2 border-t border-slate-100 pt-4">
        {onCancel ? (
          <Button type="button" variant="secondary" onClick={onCancel}>
            Cancelar
          </Button>
        ) : null}
        <Button type="submit" loading={submitting}>
          {submitLabel}
        </Button>
      </div>
    </form>
  );
}

/**
 * Helper to translate a Zod parse failure into the
 * {@link Form}'s expected `fieldErrors` shape.
 */
export function zodFieldErrors(err: unknown): Record<string, string> {
  if (
    err &&
    typeof err === "object" &&
    "issues" in err &&
    Array.isArray((err as { issues: unknown[] }).issues)
  ) {
    const out: Record<string, string> = {};
    for (const issue of (err as { issues: { path: (string | number)[]; message: string }[] })
      .issues) {
      const path = issue.path.join(".");
      if (path && !(path in out)) out[path] = issue.message;
    }
    return out;
  }
  return {};
}
