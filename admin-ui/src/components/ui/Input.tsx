import { forwardRef, useId, type InputHTMLAttributes } from "react";

/**
 * Text input wired to a label. The label is associated via
 * htmlFor + the auto-generated id, so screen readers read them
 * together. Errors render below the field in red. Required
 * fields get a visible asterisk.
 */
export interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  label: string;
  // exactOptionalPropertyTypes: callers always pass `errors[key]`
  // which is `string | undefined`. We accept undefined so the
  // page code can splat the whole map without conditional spread.
  error?: string | undefined;
  hint?: string | undefined;
}

export const Input = forwardRef<HTMLInputElement, InputProps>(function Input(
  { label, error, hint, required, id, className, ...rest },
  ref,
) {
  const autoId = useId();
  const inputId = id ?? autoId;
  const describedBy: string[] = [];
  if (error) describedBy.push(`${inputId}-error`);
  if (hint) describedBy.push(`${inputId}-hint`);

  return (
    <div className={className}>
      <label
        htmlFor={inputId}
        className="mb-1 block text-sm font-medium text-slate-700"
      >
        {label}
        {required ? (
          <span aria-hidden="true" className="ml-0.5 text-red-600">
            *
          </span>
        ) : null}
      </label>
      <input
        ref={ref}
        id={inputId}
        required={required}
        aria-invalid={error ? true : undefined}
        aria-describedby={describedBy.join(" ") || undefined}
        className={[
          "w-full rounded border bg-white px-3 py-2 text-sm text-slate-900",
          "outline-none transition-colors",
          error
            ? "border-red-400 focus:border-red-500 focus:ring-1 focus:ring-red-500"
            : "border-slate-300 focus:border-sky-500 focus:ring-1 focus:ring-sky-500",
          "disabled:cursor-not-allowed disabled:bg-slate-100",
        ].join(" ")}
        {...rest}
      />
      {hint && !error ? (
        <p id={`${inputId}-hint`} className="mt-1 text-xs text-slate-500">
          {hint}
        </p>
      ) : null}
      {error ? (
        <p id={`${inputId}-error`} role="alert" className="mt-1 text-xs text-red-600">
          {error}
        </p>
      ) : null}
    </div>
  );
});
