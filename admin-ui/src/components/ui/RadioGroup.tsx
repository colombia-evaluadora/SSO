import { forwardRef, useId } from "react";

/**
 * A single radio option. {@code description} renders under
 * the label as muted helper text — used to expand the
 * long-form meaning of the choice (e.g. "REST: classic
 * gateway routing rule" vs "QUERY: spin up a fresh
 * query-service container").
 */
export interface RadioOption<T extends string> {
  value: T;
  label: string;
  description?: string;
}

/**
 * Radio-group picker wired to a label, the same way
 * {@link Input} is. Used for low-cardinality form choices
 * (2-4 options) where a {@code <select>} would lose the
 * affordance of seeing every alternative at a glance.
 *
 * <p>Conventions mirror {@code Input.tsx} line-for-line:
 * {@code forwardRef} + {@code useId} + {@code aria-invalid}
 * + {@code aria-describedby} + the {@code error / hint /
 * required} triple. {@code exactOptionalPropertyTypes} is
 * on in this project — declare optional props with the
 * {@code | undefined} tail so callers can splat an
 * {@code errors[key]} record without a conditional spread.
 */
export interface RadioGroupProps<T extends string> {
  name: string;
  value: T;
  options: ReadonlyArray<RadioOption<T>>;
  onChange: (value: T) => void;
  label?: string | undefined;
  error?: string | undefined;
  hint?: string | undefined;
  required?: boolean;
  id?: string | undefined;
}

export const RadioGroup = forwardRef<HTMLFieldSetElement, RadioGroupProps<string>>(
  function RadioGroup(
    { name, value, options, onChange, label, error, hint, required, id },
    ref,
  ) {
    const autoId = useId();
    const groupId = id ?? autoId;
    const describedBy: string[] = [];
    if (error) describedBy.push(`${groupId}-error`);
    if (hint) describedBy.push(`${groupId}-hint`);

    return (
      <fieldset ref={ref} id={groupId} aria-describedby={describedBy.join(" ") || undefined}>
        {label ? (
          <legend className="mb-1 block text-sm font-medium text-slate-700">
            {label}
            {required ? (
              <span aria-hidden="true" className="ml-0.5 text-red-600">
                *
              </span>
            ) : null}
          </legend>
        ) : null}
        <div className="space-y-2">
          {options.map((opt) => {
            const optId = `${groupId}-${opt.value}`;
            const selected = opt.value === value;
            return (
              <label
                key={opt.value}
                htmlFor={optId}
                className={[
                  "flex cursor-pointer items-start gap-3 rounded border px-3 py-2 text-sm transition-colors",
                  selected
                    ? "border-sky-500 bg-sky-50 text-slate-900"
                    : "border-slate-300 bg-white text-slate-700 hover:bg-slate-50",
                  error ? "border-red-400" : "",
                ].join(" ")}
              >
                <input
                  id={optId}
                  type="radio"
                  name={name}
                  value={opt.value}
                  checked={selected}
                  onChange={() => onChange(opt.value)}
                  aria-invalid={error ? true : undefined}
                  className="mt-0.5 h-4 w-4 cursor-pointer accent-sky-600"
                />
                <span className="flex-1">
                  <span className="block font-medium">{opt.label}</span>
                  {opt.description ? (
                    <span className="mt-0.5 block text-xs text-slate-500">
                      {opt.description}
                    </span>
                  ) : null}
                </span>
              </label>
            );
          })}
        </div>
        {hint && !error ? (
          <p id={`${groupId}-hint`} className="mt-1 text-xs text-slate-500">
            {hint}
          </p>
        ) : null}
        {error ? (
          <p id={`${groupId}-error`} role="alert" className="mt-1 text-xs text-red-600">
            {error}
          </p>
        ) : null}
      </fieldset>
    );
  },
);