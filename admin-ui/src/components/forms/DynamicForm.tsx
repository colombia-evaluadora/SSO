import { useMemo, useState } from "react";
import { Input } from "@/components/ui/Input";
import { Button } from "@/components/ui/Button";
import {
  extractPlaceholders,
  parseQueryDetail,
  type FieldValidation,
} from "@/pages/queries/dynamicForm";

/**
 * Form auto-generado a partir del SQL de una query del catálogo.
 *
 * <p>El form no sabe nada de la tabla ni del SQL: solo lee los
 * {@code :placeholder} y rinde un input por cada uno. La
 * metadata declarada en {@code detail.fieldTypes} /
 * {@code detail.validate} (JSON) decide el tipo del input, si
 * es obligatorio, y si el submit debe validar formato antes
 * de enviar.
 *
 * <p>Si una query no tiene placeholders, el form rinde un único
 * botón "Ejecutar" sin inputs (caso "listar todo").
 *
 * <p>Validación cliente es solo de formato / required /
 * coherencia visual. <b>Nunca</b> reemplaza constraints de la DB
 * (la fuente de verdad es el ejecutor del query-service). El
 * backend igual rechaza o acepta cualquier cosa que pase
 * {@code MapSqlParameterSource}.
 */

interface Props {
  /** SQL de la query; leemos los placeholders de acá. */
  sql: string;
  /** JSON libre donde el admin declara tipos / validaciones. */
  detail: string | null | undefined;
  /** Valores por defecto (útil para re-ejecutar la misma query). */
  initialValues?: Record<string, string> | undefined;
  submitting?: boolean;
  onSubmit: (values: Record<string, string>) => Promise<void>;
  onCancel?: () => void;
  submitLabel?: string;
  /** Botón extra a la izquierda (ej: "Limpiar", "Cargar ejemplo"). */
  extraActions?: React.ReactNode;
}

/**
 * Reglas de validación que aplican ANTES de submit:
 * <ul>
 *   <li>{@code required} → no aceptar string vacío</li>
 *   <li>{@code format} → regex liviano por tipo (email/url/uuid)</li>
 *   <li>{@code minLength} / {@code maxLength} → bounds de longitud</li>
 *   <li>Si el {@code fieldTypes[name] === "number"}, el valor
 *       debe ser parseable como Number; el form guarda el
 *       string crudo y la conversión a número la hace el padre.</li>
 * </ul>
 */
function validateValue(
  value: string,
  rule: FieldValidation | undefined,
  fieldType: string | undefined,
): string | null {
  if (rule?.required && !value.trim()) return "obligatorio";
  if (fieldType === "number" && value && Number.isNaN(Number(value))) {
    return "debe ser número";
  }
  if (rule?.format === "email" && value) {
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) return "email inválido";
  }
  if (rule?.format === "url" && value) {
    try { new URL(value); } catch { return "URL inválida"; }
  }
  if (rule?.format === "uuid" && value) {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) {
      return "UUID inválido";
    }
  }
  if (rule?.minLength != null && value.length < rule.minLength) {
    return `mínimo ${rule.minLength} caracteres`;
  }
  if (rule?.maxLength != null && value.length > rule.maxLength) {
    return `máximo ${rule.maxLength} caracteres`;
  }
  return null;
}

/**
 * Mapea el {@code fieldType} declarado al atributo `type`
 * del <input>. Nota: para boolean usamos un checkbox a
 * través de un input type=checkbox — ver `renderField`.
 */
function inputTypeFor(t: string | undefined): "text" | "number" | "email" | "date" {
  if (t === "number") return "number";
  if (t === "email") return "email";
  if (t === "date") return "date";
  return "text";
}

export function DynamicForm({
  sql,
  detail,
  initialValues,
  submitting,
  onSubmit,
  onCancel,
  submitLabel = "Ejecutar",
  extraActions,
}: Props) {
  const placeholders = useMemo(() => extractPlaceholders(sql), [sql]);
  const meta = useMemo(() => parseQueryDetail(detail), [detail]);
  const rules = meta.validate ?? {};

  const [values, setValues] = useState<Record<string, string>>(
    () =>
      Object.fromEntries(
        placeholders.map((p) => [p, initialValues?.[p] ?? ""]),
      ),
  );
  const [errors, setErrors] = useState<Record<string, string>>({});

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const next: Record<string, string> = {};
    let hasError = false;
    for (const p of placeholders) {
      const t = meta.fieldTypes?.[p];
      const err = validateValue(values[p] ?? "", rules[p], t);
      if (err) {
        next[p] = err;
        hasError = true;
      }
    }
    setErrors(next);
    if (hasError) return;
    void onSubmit(values);
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="flex flex-col gap-3"
      data-testid="dynamic-form"
      noValidate
    >
      {placeholders.length === 0 ? (
        <p className="text-xs text-slate-500">
          Esta query no tiene parámetros. Click en ejecutar para correrla.
        </p>
      ) : (
        placeholders.map((name) => {
          const ft = meta.fieldTypes?.[name];
          if (ft === "boolean") {
            return (
              <label
                key={name}
                className="flex items-center gap-2 text-sm text-slate-700"
              >
                <input
                  type="checkbox"
                  checked={values[name] === "true"}
                  onChange={(e) =>
                    setValues((v) => ({
                      ...v,
                      [name]: e.target.checked ? "true" : "false",
                    }))
                  }
                  className="rounded border-slate-300 text-sky-600 focus:ring-sky-500"
                />
                <span>
                  {name}
                  {rules[name]?.required ? (
                    <span aria-hidden="true" className="ml-0.5 text-red-600">
                      *
                    </span>
                  ) : null}
                </span>
              </label>
            );
          }
          return (
            <Input
              key={name}
              label={name}
              type={inputTypeFor(ft)}
              required={rules[name]?.required ?? false}
              value={values[name]}
              onChange={(e) =>
                setValues((v) => ({ ...v, [name]: e.target.value }))
              }
              error={errors[name]}
              hint={
                ft === "number" && !errors[name]
                  ? "valor numérico"
                  : undefined
              }
            />
          );
        })
      )}

      <div className="mt-2 flex items-center justify-between gap-2">
        <div className="flex gap-2">{extraActions}</div>
        <div className="flex gap-2">
          {onCancel ? (
            <Button type="button" variant="secondary" onClick={onCancel}>
              Cancelar
            </Button>
          ) : null}
          <Button
            type="submit"
            {...(submitting ? { loading: true } : {})}
            data-testid="dynamic-form-submit"
          >
            {submitLabel}
          </Button>
        </div>
      </div>
    </form>
  );
}
