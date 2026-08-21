import { useMemo, useState } from "react";
import { Drawer } from "@/components/ui/Drawer";
import { Input } from "@/components/ui/Input";
import { Button } from "@/components/ui/Button";
import { Modal } from "@/components/ui/Modal";
import { Form, zodFieldErrors } from "@/components/forms/Form";
import { SqlEditor } from "@/components/forms/SqlEditor";
import { queryFormSchema, type QueryFormValues } from "@/schemas";
import { useMicroservices } from "@/hooks/useMicroservices";
import type { ParamConstraint, QueryAdminResponse } from "@/api/types";
import { useParamTypes } from "@/api/useParamTypes";
import { scanPlaceholders, getImplicitSystemType } from "@/lib/placeholderScanner";

/**
 * Acuña el UID de un query nuevo. `crypto.randomUUID` existe en
 * los navegadores objetivo y en jsdom/Node 19+ para los tests; el
 * fallback cubre el caso de servir el admin-ui por http:// en LAN,
 * donde el contexto no es seguro y la API no queda expuesta.
 *
 * <p>El formato encaja con el regex legacy del catálogo
 * ({@code [a-zA-Z0-9_-]}) y con VARCHAR(64): un UUID canónico
 * ocupa 36 caracteres.
 */
function newQueryUid(): string {
  const c = globalThis.crypto;
  if (c && typeof c.randomUUID === "function") return c.randomUUID();
  return `q-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

/**
 * V62 — separa el tipo base del sufijo de obligatoriedad
 * ({@code "BIGINT!"} → {@code {base: "BIGINT", required: true}}).
 * Espejo en TS de {@code ParamTypes.parseDeclaration} en el backend
 * — sin sufijo, el parámetro es nullable por defecto (null explícito
 * u omitir el campo bindean NULL de SQL en vez de tumbar la
 * petición; ver spec 2026-08-13/14).
 *
 * <p>V63 — además separa la clasificación de archivo
 * ({@code "FILE:perfilUsuario"} → {@code {base: "FILE",
 * fileClassification: "perfilUsuario", ...}}). Sólo tiene sentido
 * cuando {@code base === "FILE"}; para cualquier otro tipo queda en
 * cadena vacía. El orden de los sufijos es fijo: primero la
 * clasificación, después el de obligatoriedad
 * ({@code "FILE:perfilUsuario!"}, nunca al revés) — mismo contrato
 * que {@code ParamTypes.parseDeclaration}.
 *
 * <p>V65 — un TERCER componente opcional, sólo válido junto a una
 * clasificación no vacía: el nombre de OTRO campo de texto del mismo
 * multipart que trae el código de establecimiento
 * ({@code "FILE:actividad:idEstablecimiento"} → {@code {...,
 * fileClassification: "actividad", fileEstablishmentField:
 * "idEstablecimiento"}}).
 */
function splitDeclaration(
  raw: string | undefined,
  requiredSuffix: string,
  fileClassificationSeparator: string,
): { base: string; required: boolean; fileClassification: string; fileEstablishmentField: string } {
  if (!raw) return { base: "", required: false, fileClassification: "", fileEstablishmentField: "" };
  const required = requiredSuffix !== "" && raw.endsWith(requiredSuffix);
  const sinObligatorio = required ? raw.slice(0, -requiredSuffix.length) : raw;
  const filePrefix = `FILE${fileClassificationSeparator}`;
  if (sinObligatorio.startsWith(filePrefix)) {
    const resto = sinObligatorio.slice(filePrefix.length);
    const separador = resto.indexOf(fileClassificationSeparator);
    const fileClassification = separador < 0 ? resto : resto.slice(0, separador);
    const fileEstablishmentField = separador < 0 ? "" : resto.slice(separador + 1);
    return { base: "FILE", required, fileClassification, fileEstablishmentField };
  }
  return { base: sinObligatorio, required, fileClassification: "", fileEstablishmentField: "" };
}

/** Inverso de {@link splitDeclaration}: recompone el string que se
 *  guarda en {@code paramTypes}. */
function composeDeclaration(
  base: string,
  required: boolean,
  fileClassification: string,
  fileEstablishmentField: string,
  requiredSuffix: string,
  fileClassificationSeparator: string,
): string {
  let conClasificacion = base;
  if (base === "FILE" && fileClassification) {
    conClasificacion = `FILE${fileClassificationSeparator}${fileClassification}`;
    // V65 — el campo de establecimiento sólo tiene sentido pegado a
    // una clasificación no vacía; sin clasificación se descarta en
    // silencio (mismo criterio que el backend: parseDeclaration sólo
    // lo llena si el segundo componente también está presente).
    if (fileEstablishmentField) {
      conClasificacion += `${fileClassificationSeparator}${fileEstablishmentField}`;
    }
  }
  return required ? `${conClasificacion}${requiredSuffix}` : conClasificacion;
}

/**
 * V65 — los dos inputs que aparecen bajo el selector de tipo cuando
 * éste es {@code FILE}: la clasificación (con sugerencias del
 * catálogo conocido, pero libre — el backend acepta cualquier valor
 * con forma válida) y, sólo si hay clasificación, el campo de
 * establecimiento. Un único componente para no duplicar el JSX entre
 * la tabla de placeholders detectados y la de tipos manuales, que
 * antes de esto ya repetían el input de clasificación dos veces.
 */
function FileClassificationInputs({
  placeholder,
  fileClassification,
  fileEstablishmentField,
  onClassificationChange,
  onEstablishmentFieldChange,
  knownFileClassifications,
  establishmentScopedFileClassifications,
}: {
  placeholder: string;
  fileClassification: string;
  fileEstablishmentField: string;
  onClassificationChange: (value: string) => void;
  onEstablishmentFieldChange: (value: string) => void;
  knownFileClassifications: string[];
  establishmentScopedFileClassifications: string[];
}) {
  const datalistId = `file-classifications-${placeholder}`;
  const sugiereEstablecimiento = establishmentScopedFileClassifications.includes(fileClassification);
  return (
    <>
      <input
        type="text"
        list={datalistId}
        value={fileClassification}
        onChange={(e) => onClassificationChange(e.target.value)}
        placeholder="Clasificación (opcional), ej. perfilUsuario"
        aria-label={`${placeholder} clasificación de archivo`}
        title="Carpeta S3 donde file-service guarda este archivo: <clasificación>/<pk>.<extensión>. Vacío = formato genérico <pk>/<nombre>."
        className="mt-1 w-full rounded border border-slate-300 bg-white px-2 py-1 text-xs outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
      />
      <datalist id={datalistId}>
        {knownFileClassifications.map((c) => (
          <option key={c} value={c} />
        ))}
      </datalist>
      {fileClassification && (
        <input
          type="text"
          value={fileEstablishmentField}
          onChange={(e) => onEstablishmentFieldChange(e.target.value)}
          placeholder={
            sugiereEstablecimiento
              ? "Campo con el código de establecimiento, ej. idEstablecimiento"
              : "Campo de establecimiento (opcional)"
          }
          aria-label={`${placeholder} campo de establecimiento`}
          title="Nombre de OTRO campo de texto del mismo multipart que trae el código de establecimiento (validado contra testablecimiento.codigo) — se antepone a la clasificación en la clave S3. Vacío = sin ese segmento."
          className="mt-1 w-full rounded border border-slate-300 bg-white px-2 py-1 text-xs outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
        />
      )}
    </>
  );
}

interface Props {
  open: boolean;
  query: QueryAdminResponse | null;
  onClose: () => void;
  onSubmit: (values: QueryFormValues & { id?: number }) => Promise<void>;
}

/**
 * Form drawer for the Queries Catalog admin CRUD. Notable controls:
 * <ul>
 *   <li>{@code microserviceId} — a {@code <select>} populated
 *       from {@link useMicroservices} filtered to {@code kind=QUERY}.
 *       {@code null} = "global" query (canonical
 *       {@code query-service} serves it).</li>
 *   <li>{@code executionMode} (V28) — how query-service executes
 *       the row: SELECT (default), PROCEDURE (CALL schema.proc),
 *       or FUNCTION (SELECT * FROM schema.func). The backend
 *       validates the SQL's first keyword matches the mode at
 *       save time.</li>
 *   <li>{@code pathTemplate} (V27) — URL suffix that exposes this
 *       query as a first-class HTTP endpoint. Composed with the
 *       microservice's {@code REQUEST_URI} prefix at request time.
 *       Empty = legacy (uuid in body only).</li>
 *   <li>{@code query} — multi-line text for the raw SQL.
 *       {@code :placeholder} tokens pass through to JDBC
 *       {@code MapSqlParameterSource}.</li>
 * </ul>
 */
export function QueryFormDrawer({ open, query, onClose, onSubmit }: Props) {
  const services = useMicroservices();

  const initialValues: QueryFormValues = useMemo(
    () => ({
      // UID automático al crear. `open` entra en las deps a
      // propósito: este componente NO se desmonta al cerrar el
      // drawer (Drawer devuelve null, el Form de adentro es el
      // que se remonta), así que sin esto el segundo "Nuevo
      // query" reusaría el UID del primero y chocaría contra el
      // unique de la columna UUID.
      uuid: query?.uuid ?? (open ? newQueryUid() : ""),
      query: query?.query ?? "",
      publicEnd: query?.publicEnd ?? false,
      captcha: query?.captcha ?? false,
      detail: query?.detail ?? "",
      action: query?.action ?? "",
      style: query?.style ?? "",
      microserviceId: query?.microserviceId ?? null,

      httpMethod: query?.httpMethod ?? "POST",
      pathTemplate: query?.pathTemplate ?? null,
      outParamNames: query?.outParamNames ?? null,
      paramTypes: (query?.paramTypes ?? {}) as Record<string, string>,
      // V81 — restricciones de formato opcionales por placeholder.
      paramConstraints: (query?.paramConstraints ?? {}) as Record<string, ParamConstraint>,
    }),
    [query, open],
  );

  const queryInstances = useMemo(
    () => (services.data ?? []).filter((m) => m.kind === "QUERY"),
    [services.data],
  );

  return (
    <Drawer
      open={open}
      onClose={onClose}
      title={query ? `Editar query: ${query.uuid}` : "Nuevo query"}
      description="Define el SQL y la metadata. El binding al microservicio decide qué query-service-<instance> lo sirve."
      footer={null}
      width="lg"
    >
      <Form<QueryFormValues>
        initialValues={initialValues}
        validate={(values) => {
          const result = queryFormSchema.safeParse(values);
          if (result.success) return {};
          return zodFieldErrors(result.error);
        }}
        onSubmit={async (values) => {
          await onSubmit(query ? { id: query.id, ...values } : values);
        }}
        onCancel={onClose}
        submitLabel={query ? "Guardar cambios" : "Crear"}
      >
        {({ values, setField, errors }) => {
          // Misma regla que QueryAdminService.deriveExecutionMode:
          // el modo sale del primer keyword del SQL. Se recalcula
          // aquí sólo para decidir qué mostrar; la fuente de verdad
          // es el backend.
          const isProcedure = /^\s*call\b/i.test(values.query ?? "");
          // V49 — tipos por placeholder. La detección corre en
          // cliente cada vez que el SQL cambia; los tipos asignados
          // viven en values.paramTypes y se preservan entre iteraciones
          // aunque un placeholder desaparezca temporalmente del SQL.
          const placeholders = scanPlaceholders(values.query ?? "");
          const detected = placeholders;
          const paramTypes = (values.paramTypes ?? {}) as Record<string, string>;
          const paramConstraints = (values.paramConstraints ?? {}) as Record<
            string,
            ParamConstraint
          >;
          return (
          <>
            <div className="grid grid-cols-2 gap-3">
              {/* UID automático. Al crear se acuña solo y el campo
                  queda read-only (con "Regenerar" por si el admin
                  quiere otro); al editar sigue siendo editable
                  porque hay filas legacy con handles con
                  significado que a veces se corrigen a mano. */}
              {query ? (
                <Input
                  label="UUID"
                  value={values.uuid}
                  onChange={(e) => setField("uuid", e.target.value)}
                  error={errors.uuid}
                  hint="Handle público del consumidor — cambiarlo rompe a quien ya lo tenga cableado"
                />
              ) : (
                <div>
                  <Input
                    label="UUID"
                    value={values.uuid}
                    readOnly
                    onChange={() => {}}
                    error={errors.uuid}
                    hint="Generado automáticamente"
                  />
                  <Button
                    type="button"
                    variant="secondary"
                    size="sm"
                    className="mt-1"
                    onClick={() => setField("uuid", newQueryUid())}
                  >
                    Regenerar
                  </Button>
                </div>
              )}
              {/* El microservicio va aquí, junto al UUID: es lo que
                  decide qué query-service sirve la fila y qué
                  prefijo lleva la URL, así que se decide antes de
                  escribir el SQL, no después. Ocupa el hueco que
                  dejó el campo "Tipo" al retirarse. */}
              <div>
                <label
                  htmlFor="query-microservice"
                  className="mb-1 block text-sm font-medium text-slate-700"
                >
                  Microservicio (kind=QUERY)
                </label>
                <select
                  id="query-microservice"
                  value={
                    values.microserviceId == null
                      ? ""
                      : String(values.microserviceId)
                  }
                  onChange={(e) =>
                    setField(
                      "microserviceId",
                      e.target.value === "" ? null : Number(e.target.value),
                    )
                  }
                  className="w-full rounded border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
                >
                  <option value="">Sin binding (global)</option>
                  {queryInstances.map((m) => (
                    <option key={m.id} value={String(m.id)}>
                      #{m.id} · {m.instanceName ?? m.serviceId}
                      {m.dialect ? ` (${m.dialect})` : ""}
                    </option>
                  ))}
                </select>
                {queryInstances.length === 0 && !services.isLoading ? (
                  <p className="mt-1 text-[11px] text-slate-500">
                    No hay microservicios QUERY aprovisionados aún.
                  </p>
                ) : null}
              </div>
            </div>
            {/* La URL completa se muestra fuera de la rejilla, a lo
                ancho: es la composición de microservicio + método +
                plantilla, así que no pertenece a ninguno de los tres
                campos por separado. */}
            {values.microserviceId && values.pathTemplate ? (
              <p className="mt-2 text-[11px] text-slate-500">
                URL completa:{" "}
                <code className="rounded bg-slate-100 px-1">
                  {values.httpMethod} /&lt;request_uri&gt;
                  {values.pathTemplate}
                </code>{" "}
                — el prefijo REQUEST_URI lo define el microservicio.
              </p>
            ) : null}
            <div className="h-3" />
            <label className="block text-sm">
              <span className="mb-1 block font-medium text-slate-700">
                SQL<span className="ml-0.5 text-red-600">*</span>
              </span>
              <SqlEditor
                value={values.query}
                onChange={(next) => setField("query", next)}
                rows={6}
                invalid={!!errors.query}
                ariaLabel="SQL"
                placeholder={
                  "SELECT id, nombre FROM establecimiento\nWHERE nombre LIKE :PARAM.NOMBRE\n  AND owner = :CONTEXT.USER_ID\nLIMIT :QUERY.SIZE"
                }
              />
              {errors.query ? (
                <p role="alert" className="mt-1 text-xs text-red-600">
                  {errors.query}
                </p>
              ) : null}
              <p className="mt-1 text-[11px] text-slate-500">
                Cada parámetro lleva el prefijo de su origen:{" "}
                <code>:PARAM.X</code> (variables de la ruta),{" "}
                <code>:QUERY.X</code> (query string),{" "}
                <code>:BODY.X.Y</code> (cuerpo JSON) y{" "}
                <code>:CONTEXT.USER_ID</code>, <code>:CONTEXT.EMAIL</code>,{" "}
                <code>:CONTEXT.ROLES</code> (CSV),{" "}
                <code>:CONTEXT.ROLES_ARRAY</code> (array PG) — estos últimos
                salen del JWT y el cliente no puede fabricarlos.
              </p>
              <p className="mt-1 text-[11px] text-slate-500">
                La paginación la escribes tú:{" "}
                <code>LIMIT :QUERY.SIZE OFFSET :QUERY.OFFSET</code>. El SQL
                se ejecuta tal cual lo ves — ya no se le añade nada por
                detrás.
              </p>
            </label>
            <div className="h-3" />
            <ParamTypesSection
              detected={detected}
              value={paramTypes}
              onChange={(next) => setField("paramTypes", next)}
              constraints={paramConstraints}
              onConstraintsChange={(next) => setField("paramConstraints", next)}
            />
            <div className="h-3" />
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label
                  htmlFor="query-http-method"
                  className="mb-1 block text-sm font-medium text-slate-700"
                >
                  Método HTTP
                </label>
                <select
                  id="query-http-method"
                  value={values.httpMethod}
                  onChange={(e) =>
                    setField(
                      "httpMethod",
                      e.target.value as QueryFormValues["httpMethod"],
                    )
                  }
                  className="w-full rounded border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
                >
                  <option value="GET">GET — leer, sin cuerpo</option>
                  <option value="POST">POST — leer o crear</option>
                  <option value="PUT">PUT — actualizar</option>
                  <option value="PATCH">PATCH — actualizar parcial (RFC 5789)</option>
                </select>
                <p className="mt-1 text-[11px] text-slate-500">
                  Solo aplica cuando hay path template. DELETE no se admite:
                  para borrar, publica un procedimiento y llámalo con{" "}
                  <code>CALL</code>.
                </p>
              </div>
              <Input
                label="Path template"
                value={values.pathTemplate ?? ""}
                onChange={(e) =>
                  setField(
                    "pathTemplate",
                    e.target.value.trim() === "" ? null : e.target.value,
                  )
                }
                error={errors.pathTemplate}
                hint="Sufijo de URL DENTRO del microservicio, con variables :MAYÚSCULA (ej /establecimiento/:NOMBRE), que se bindean como :PARAM.NOMBRE. Vacío = solo accesible vía POST /<svc>/query (legacy)."
              />
              {isProcedure ? (
                <Input
                  label="OUT params"
                  value={values.outParamNames ?? ""}
                  onChange={(e) =>
                    setField(
                      "outParamNames",
                      e.target.value.trim() === "" ? null : e.target.value,
                    )
                  }
                  error={errors.outParamNames}
                  hint="Nombres :placeholder separados por comas (ej :out_status,:out_message)."
                />
              ) : null}
            </div>
            <div className="h-2" />
            {/*
              Modo y dialecto ya no se piden: el backend los deriva del
              SQL y del microservicio dueño. Se muestran igualmente para
              que siga siendo visible qué se va a guardar, pero sin que
              se puedan contradecir con el SQL.
            */}
            <p className="text-[11px] text-slate-500">
              Modo de ejecución:{" "}
              <strong>{isProcedure ? "PROCEDURE" : "SELECT"}</strong> —
              derivado del primer keyword del SQL. El dialecto lo hereda del
              microservicio seleccionado.
            </p>
            <div className="h-3" />
            <div className="flex items-center gap-6">
              <label className="flex items-center gap-2 text-sm text-slate-700">
                <input
                  type="checkbox"
                  checked={values.publicEnd}
                  onChange={(e) => setField("publicEnd", e.target.checked)}
                  className="rounded border-slate-300 text-sky-600 focus:ring-sky-500"
                />
                Endpoint público
              </label>
              <label className="flex items-center gap-2 text-sm text-slate-700">
                <input
                  type="checkbox"
                  checked={values.captcha}
                  onChange={(e) => setField("captcha", e.target.checked)}
                  className="rounded border-slate-300 text-sky-600 focus:ring-sky-500"
                />
                Requiere captcha
              </label>
            </div>
            <div className="h-3" />
            <details className="rounded border border-slate-200 bg-slate-50 px-3 py-2 text-xs">
              <summary className="cursor-pointer font-medium text-slate-700">
                Metadata UI (detail / action / style)
              </summary>
              <div className="mt-2 grid gap-3">
                <label className="block">
                  <span className="mb-1 block font-medium text-slate-700">detail</span>
                  <textarea
                    value={values.detail}
                    onChange={(e) => setField("detail", e.target.value)}
                    rows={3}
                    className="w-full rounded border border-slate-300 bg-white px-3 py-2 font-mono text-[11px] outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
                    placeholder='{"fields":[{"key":"username","label":"Usuario"}]}'
                  />
                </label>
                <label className="block">
                  <span className="mb-1 block font-medium text-slate-700">action</span>
                  <textarea
                    value={values.action}
                    onChange={(e) => setField("action", e.target.value)}
                    rows={2}
                    className="w-full rounded border border-slate-300 bg-white px-3 py-2 font-mono text-[11px] outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
                  />
                </label>
                <label className="block">
                  <span className="mb-1 block font-medium text-slate-700">style</span>
                  <textarea
                    value={values.style}
                    onChange={(e) => setField("style", e.target.value)}
                    rows={2}
                    className="w-full rounded border border-slate-300 bg-white px-3 py-2 font-mono text-[11px] outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
                  />
                </label>
              </div>
            </details>
            <div className="h-3" />
            <p className="text-[11px] text-slate-500">
              Los bindings a roles se gestionan en el modal "Roles" después de guardar
              (mismo patrón que Endpoints).
            </p>
          </>
          );
        }}
      </Form>
    </Drawer>
  );
}

/**
 * V49 — Sección "Tipos de parámetros" del formulario.
 *
 * <p>Auto-detecta los placeholders del SQL, los muestra como filas
 * con un dropdown por fila, y deja al autor asignar el tipo PG/JDBC
 * a cada uno. El backend rechaza el guardado si alguna :PARAM.* /
 * :BODY.* del SQL no tiene entrada — aquí damos feedback inmediato
 * con un contador que se pone rojo cuando falta alguno.
 *
 * <p>Las filas que ya tenían un tipo (de un edit anterior) se
 * restauran automáticamente cuando reaparecen en el SQL. El autor
 * puede añadir tipos manualmente para placeholders que aún no ha
 * escrito (útil para preparar el SQL).
 */
function ParamTypesSection({
  detected,
  value,
  onChange,
  constraints,
  onConstraintsChange,
}: {
  detected: string[];
  value: Record<string, string>;
  onChange: (next: Record<string, string>) => void;
  constraints: Record<string, ParamConstraint>;
  onConstraintsChange: (next: Record<string, ParamConstraint>) => void;
}) {
  const { data, isLoading, error } = useParamTypes();
  const curated = data?.curated ?? [];
  const requiredSuffix = data?.requiredSuffix ?? "!";
  const fileClassificationSeparator = data?.fileClassificationSeparator ?? ":";
  // V65 — catálogo sugerido de clasificaciones y su subconjunto
  // establishment-scoped, ver el javadoc de ParamTypesResponse.
  const knownFileClassifications = data?.knownFileClassifications ?? [];
  const establishmentScopedFileClassifications =
    data?.establishmentScopedFileClassifications ?? [];
  // V81 — subconjuntos que deciden qué reglas ofrece el modal de
  // restricciones para cada placeholder.
  const numericTypes = data?.numericTypes ?? [];
  const textTypes = data?.textTypes ?? [];

  // V81 — placeholder cuya modal de restricciones está abierta ahora
  // mismo (null = cerrada). Una sola modal reutilizada para todas las
  // filas — evita montar N <dialog> ocultos.
  const [editingConstraintsFor, setEditingConstraintsFor] = useState<string | null>(null);

  function setConstraint(placeholder: string, patch: ParamConstraint) {
    onConstraintsChange({ ...constraints, [placeholder]: { ...constraints[placeholder], ...patch } });
  }

  function clearConstraint(placeholder: string) {
    const next = { ...constraints };
    delete next[placeholder];
    onConstraintsChange(next);
  }

  /**
   * V81 — ¿este placeholder puede tener restricciones de formato, y
   * de qué familia? Sólo {@code :BODY.*} (pedido explícitamente: las
   * reglas de formato son para campos del cuerpo, no para variables
   * de ruta ni query string) con un tipo base numérico o textual.
   */
  function constraintKind(placeholder: string, base: string): "numeric" | "text" | null {
    if (placeholder.split(".")[0] !== "BODY") return null;
    if (numericTypes.includes(base)) return "numeric";
    if (textTypes.includes(base)) return "text";
    return null;
  }

  function hasAnyRule(rule: ParamConstraint | undefined): boolean {
    if (!rule) return false;
    return (
      rule.onlyPositive != null ||
      rule.allowDecimals != null ||
      rule.maxDigits != null ||
      rule.numericText != null ||
      rule.minLength != null ||
      rule.maxLength != null
    );
  }

  /** Celda "Restricciones" compartida por la tabla de detectados y
   *  la de tipos manuales — {@code "—"} cuando no aplica. */
  function renderConstraintsCell(placeholder: string, base: string) {
    const kind = constraintKind(placeholder, base);
    if (!kind) {
      return <span className="text-slate-300">—</span>;
    }
    const configured = hasAnyRule(constraints[placeholder]);
    return (
      <button
        type="button"
        onClick={() => setEditingConstraintsFor(placeholder)}
        className={
          "rounded px-2 py-0.5 text-[11px] font-medium " +
          (configured
            ? "bg-sky-100 text-sky-800 hover:bg-sky-200"
            : "bg-slate-100 text-slate-600 hover:bg-slate-200")
        }
        title="Restricciones de formato adicionales (positivo, decimales, longitud, sólo dígitos...)"
      >
        {configured ? "Editado ✓" : "Configurar"}
      </button>
    );
  }

  // Cuenta cuántos de los placeholders detectados están tipados.
  // El backend exige tipo explícito en :PARAM.* / :BODY.* / :BODY_RAW.*
  // (QueryAdminService.validateCoverage incluye los tres en el set
  // `required`) — :CONTEXT.* y :QUERY.{SIZE,OFFSET} los bindea el
  // sistema y no cuentan como "faltantes" para el badge, aunque los
  // seguimos mostrando en la tabla para que el autor los vea.
  //
  // V62-bis — BODY_RAW faltaba acá (mismo olvido que en el regex de
  // placeholderScanner.ts): el badge nunca marcaba un :BODY_RAW.X
  // sin tipar como "faltante", así que el formulario parecía OK
  // hasta que el guardado rebotaba con 400 "PARAM_TYPES incompleto".
  const REQUIRED_NS = new Set(["PARAM", "BODY", "BODY_RAW"]);
  const required = detected.filter((p) => REQUIRED_NS.has(p.split(".")[0] ?? ""));
  const typed = required.filter((p) => value[p]).length;
  const missing = required.length - typed;

  function setType(placeholder: string, type: string) {
    const next = { ...value };
    if (type === "" || type === undefined) {
      delete next[placeholder];
    } else {
      // V62 — el dropdown sólo elige el tipo base; se preserva el
      // sufijo de obligatoriedad que ya tuviera la fila. V63 — la
      // clasificación sólo se preserva si el tipo se queda en FILE;
      // cambiar a otro tipo la descarta (no tiene sentido en, p. ej.,
      // BIGINT). V65 — el campo de establecimiento sigue la misma
      // regla que la clasificación.
      const {
        required: wasRequired,
        fileClassification: wasClassification,
        fileEstablishmentField: wasEstablishmentField,
      } = splitDeclaration(next[placeholder], requiredSuffix, fileClassificationSeparator);
      next[placeholder] = composeDeclaration(
        type,
        wasRequired,
        type === "FILE" ? wasClassification : "",
        type === "FILE" ? wasEstablishmentField : "",
        requiredSuffix,
        fileClassificationSeparator,
      );
    }
    onChange(next);
  }

  /**
   * V62 — checkbox "obligatorio" por fila. Sin tipo asignado
   * todavía no hay nada que marcar como obligatorio — el checkbox
   * de esas filas viene deshabilitado (ver render).
   */
  function setRequired(placeholder: string, isRequired: boolean) {
    const current = value[placeholder];
    if (!current) return;
    const { base, fileClassification, fileEstablishmentField } =
      splitDeclaration(current, requiredSuffix, fileClassificationSeparator);
    onChange({
      ...value,
      [placeholder]: composeDeclaration(
        base, isRequired, fileClassification, fileEstablishmentField,
        requiredSuffix, fileClassificationSeparator,
      ),
    });
  }

  /**
   * V63 — input (dropdown con opción libre) que aparece sólo cuando
   * el tipo elegido es {@code FILE}. Vacío = sin clasificar, mismo
   * formato de clave que siempre tuvo file-service
   * ({@code <pk>/<nombre>}).
   */
  function setFileClassification(placeholder: string, classification: string) {
    const current = value[placeholder];
    if (!current) return;
    const { base, required: isRequired, fileEstablishmentField } =
      splitDeclaration(current, requiredSuffix, fileClassificationSeparator);
    onChange({
      ...value,
      [placeholder]: composeDeclaration(
        base, isRequired, classification, fileEstablishmentField,
        requiredSuffix, fileClassificationSeparator,
      ),
    });
  }

  /**
   * V65 — input de texto que aparece junto a la clasificación: nombre
   * de OTRO campo de texto del mismo multipart que trae el código de
   * establecimiento. Vacío = sin ese segmento en la clave S3 (mismo
   * comportamiento que antes de V65).
   */
  function setFileEstablishmentField(placeholder: string, establishmentField: string) {
    const current = value[placeholder];
    if (!current) return;
    const { base, required: isRequired, fileClassification } =
      splitDeclaration(current, requiredSuffix, fileClassificationSeparator);
    onChange({
      ...value,
      [placeholder]: composeDeclaration(
        base, isRequired, fileClassification, establishmentField,
        requiredSuffix, fileClassificationSeparator,
      ),
    });
  }

  function addManual() {
    // Pide una key (default = placeholder vacío). El autor la puede
    // editar para reservar el tipo antes de escribir el placeholder
    // en el SQL.
    const key = window.prompt(
      "Nombre del placeholder (MAYÚSCULAS, ej PARAM.NOMBRE):",
    );
    if (!key) return;
    if (!/^[A-Z][A-Z0-9_]*(\.[A-Z][A-Z0-9_]*)*$/.test(key)) {
      window.alert("Formato inválido. Cada segmento debe ser MAYÚSCULAS y usar A-Z, 0-9, _.");
      return;
    }
    if (value[key]) {
      window.alert("Ese placeholder ya tiene tipo asignado.");
      return;
    }
    const defaultType = curated[0] ?? "TEXT";
    onChange({ ...value, [key]: defaultType });
  }

  function removeManual(placeholder: string) {
    const next = { ...value };
    delete next[placeholder];
    onChange(next);
  }

  if (isLoading) {
    return (
      <div className="rounded border border-slate-200 bg-slate-50 px-3 py-2 text-[11px] text-slate-500">
        Cargando tipos disponibles…
      </div>
    );
  }
  if (error) {
    return (
      <div className="rounded border border-rose-200 bg-rose-50 px-3 py-2 text-[11px] text-rose-700">
        No se pudieron cargar los tipos disponibles ({String(error)}).
      </div>
    );
  }

  const manualKeys = Object.keys(value).filter((k) => !detected.includes(k));

  return (
    <div className="rounded border border-slate-200 bg-slate-50 px-3 py-2">
      <div className="mb-2 flex items-center justify-between">
        <div>
          <div className="text-sm font-medium text-slate-700">
            Tipos de parámetros
          </div>
          <div className="text-[11px] text-slate-500">
            Auto-detectados del SQL. Asigna un tipo a cada :PARAM.* / :BODY.*.
            :CONTEXT.* y :QUERY.{'{'}SIZE,OFFSET{'}'} los bindea el sistema.
            Por defecto un parámetro acepta null (u omitirse) sin error — marca
            "Obligatorio" sólo en los que la función SIEMPRE necesita.
          </div>
        </div>
        <div
          className={
            "rounded px-2 py-0.5 text-[11px] font-medium " +
            (detected.length === 0
              ? "bg-slate-100 text-slate-600"
              : missing === 0
                ? "bg-emerald-100 text-emerald-800"
                : "bg-rose-100 text-rose-800")
          }
        >
          {detected.length === 0
            ? "Sin placeholders"
            : missing === 0
              ? `Detectados ${detected.length} — tipados ${typed} — ✓`
              : `Detectados ${detected.length} — tipados ${typed} — faltantes ${missing}`}
        </div>
      </div>

      {detected.length > 0 && (
        <div className="overflow-hidden rounded border border-slate-200 bg-white">
          <table className="w-full text-xs">
            <thead className="bg-slate-100 text-[11px] uppercase text-slate-500">
              <tr>
                <th className="px-2 py-1 text-left">Placeholder</th>
                <th className="px-2 py-1 text-left">Tipo</th>
                <th className="px-2 py-1 text-center" title="Si no se marca, el parámetro acepta null / omitirse sin error">
                  Obligatorio
                </th>
                <th className="px-2 py-1 text-center" title="Sólo para :BODY.* numéricos o de texto">
                  Restricciones
                </th>
              </tr>
            </thead>
            <tbody>
              {detected.map((p) => {
                const systemType = getImplicitSystemType(p);
                if (systemType) {
                  // El sistema lo bindea — selector deshabilitado que
                  // muestra el tipo real. El autor no tiene que (ni
                  // puede) cambiarlo: incluirlo en paramTypes
                  // sería rechazado por la validación del backend.
                  return (
                    <tr key={p} className="border-t border-slate-100">
                      <td className="px-2 py-1 font-mono">:{p}</td>
                      <td className="px-2 py-1">
                        <div className="flex items-center gap-2">
                          <select
                            value={systemType}
                            disabled
                            aria-readonly="true"
                            className="flex-1 cursor-not-allowed rounded border border-slate-200 bg-slate-100 px-2 py-1 text-xs text-slate-500"
                          >
                            <option value={systemType}>{systemType}</option>
                          </select>
                          <span className="rounded bg-slate-100 px-1.5 py-0.5 text-[10px] uppercase tracking-wide text-slate-500">
                            sistema
                          </span>
                        </div>
                      </td>
                      <td className="px-2 py-1 text-center text-slate-300">—</td>
                      <td className="px-2 py-1 text-center text-slate-300">—</td>
                    </tr>
                  );
                }
                const { base, required: isRequired, fileClassification, fileEstablishmentField } =
                  splitDeclaration(value[p], requiredSuffix, fileClassificationSeparator);
                return (
                  <tr key={p} className="border-t border-slate-100">
                    <td className="px-2 py-1 font-mono">:{p}</td>
                    <td className="px-2 py-1">
                      <select
                        value={base}
                        onChange={(e) => setType(p, e.target.value)}
                        className="w-full rounded border border-slate-300 bg-white px-2 py-1 text-xs outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
                      >
                        <option value="">— sin tipo —</option>
                        {curated.map((t) => (
                          <option key={t} value={t}>
                            {t}
                          </option>
                        ))}
                      </select>
                      {base === "FILE" && (
                        <FileClassificationInputs
                          placeholder={p}
                          fileClassification={fileClassification}
                          fileEstablishmentField={fileEstablishmentField}
                          onClassificationChange={(v) => setFileClassification(p, v)}
                          onEstablishmentFieldChange={(v) => setFileEstablishmentField(p, v)}
                          knownFileClassifications={knownFileClassifications}
                          establishmentScopedFileClassifications={establishmentScopedFileClassifications}
                        />
                      )}
                    </td>
                    <td className="px-2 py-1 text-center">
                      <input
                        type="checkbox"
                        checked={isRequired}
                        disabled={!base}
                        onChange={(e) => setRequired(p, e.target.checked)}
                        aria-label={`${p} es obligatorio`}
                        title={
                          base
                            ? "Sin marcar: acepta null u omitirse (bindea NULL). Marcado: null/omitido responde 400."
                            : "Asigna un tipo primero"
                        }
                        className="h-3.5 w-3.5 cursor-pointer accent-sky-600 disabled:cursor-not-allowed"
                      />
                    </td>
                    <td className="px-2 py-1 text-center">
                      {renderConstraintsCell(p, base)}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {manualKeys.length > 0 && (
        <div className="mt-2">
          <div className="mb-1 text-[11px] font-medium text-slate-500">
            Tipos manuales (placeholder aún no escrito)
          </div>
          <div className="overflow-hidden rounded border border-slate-200 bg-white">
            <table className="w-full text-xs">
              <tbody>
                {manualKeys.map((k) => {
                  const { base, required: isRequired, fileClassification, fileEstablishmentField } =
                    splitDeclaration(value[k], requiredSuffix, fileClassificationSeparator);
                  return (
                    <tr key={k} className="border-t border-slate-100 first:border-t-0">
                      <td className="px-2 py-1 font-mono">:{k}</td>
                      <td className="px-2 py-1">
                        <select
                          value={base}
                          onChange={(e) => setType(k, e.target.value)}
                          className="w-full rounded border border-slate-300 bg-white px-2 py-1 text-xs outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
                        >
                          <option value="">— sin tipo —</option>
                          {curated.map((t) => (
                            <option key={t} value={t}>
                              {t}
                            </option>
                          ))}
                        </select>
                        {base === "FILE" && (
                          <FileClassificationInputs
                            placeholder={k}
                            fileClassification={fileClassification}
                            fileEstablishmentField={fileEstablishmentField}
                            onClassificationChange={(v) => setFileClassification(k, v)}
                            onEstablishmentFieldChange={(v) => setFileEstablishmentField(k, v)}
                            knownFileClassifications={knownFileClassifications}
                            establishmentScopedFileClassifications={establishmentScopedFileClassifications}
                          />
                        )}
                      </td>
                      <td className="px-2 py-1 text-center">
                        <input
                          type="checkbox"
                          checked={isRequired}
                          disabled={!base}
                          onChange={(e) => setRequired(k, e.target.checked)}
                          aria-label={`${k} es obligatorio`}
                          title={
                            base
                              ? "Sin marcar: acepta null u omitirse (bindea NULL). Marcado: null/omitido responde 400."
                              : "Asigna un tipo primero"
                          }
                          className="h-3.5 w-3.5 cursor-pointer accent-sky-600 disabled:cursor-not-allowed"
                        />
                      </td>
                      <td className="px-2 py-1 text-center">
                        {renderConstraintsCell(k, base)}
                      </td>
                      <td className="px-2 py-1 text-right">
                        <button
                          type="button"
                          onClick={() => removeManual(k)}
                          className="text-rose-600 hover:underline"
                          title="Quitar tipo manual"
                        >
                          ×
                        </button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}

      <button
        type="button"
        onClick={addManual}
        className="mt-2 text-[11px] text-sky-700 hover:underline"
      >
        + Agregar tipo manualmente
      </button>

      {editingConstraintsFor && (() => {
        const placeholder = editingConstraintsFor;
        const base = splitDeclaration(
          value[placeholder], requiredSuffix, fileClassificationSeparator,
        ).base;
        const kind = constraintKind(placeholder, base);
        if (!kind) return null;
        const rule = constraints[placeholder] ?? {};
        return (
          <ParamConstraintModal
            placeholder={placeholder}
            kind={kind}
            rule={rule}
            onChange={(patch) => setConstraint(placeholder, patch)}
            onClear={() => clearConstraint(placeholder)}
            onClose={() => setEditingConstraintsFor(null)}
          />
        );
      })()}
    </div>
  );
}

/**
 * V81 — modal con las reglas de formato de un placeholder
 * {@code :BODY.*}. Sólo dos "familias" mutuamente excluyentes según
 * el tipo base declarado: numérica (positivo / decimales / máximo de
 * cifras) o de texto (sólo dígitos / longitud mínima y máxima) — ver
 * {@code ParamConstraint} en el backend.
 */
function ParamConstraintModal({
  placeholder,
  kind,
  rule,
  onChange,
  onClear,
  onClose,
}: {
  placeholder: string;
  kind: "numeric" | "text";
  rule: ParamConstraint;
  onChange: (patch: ParamConstraint) => void;
  onClear: () => void;
  onClose: () => void;
}) {
  function numberOrNull(raw: string): number | null {
    if (raw.trim() === "") return null;
    const n = Number(raw);
    return Number.isFinite(n) ? n : null;
  }

  return (
    <Modal
      open={true}
      onClose={onClose}
      title={`Restricciones — :${placeholder}`}
      description={
        kind === "numeric"
          ? "Reglas adicionales de formato para este número. Vacío = sin restricción en ese aspecto."
          : "Reglas adicionales de formato para este texto. Vacío = sin restricción en ese aspecto."
      }
      size="sm"
      footer={
        <>
          <Button type="button" variant="secondary" onClick={onClear}>
            Quitar restricciones
          </Button>
          <Button type="button" onClick={onClose}>
            Listo
          </Button>
        </>
      }
    >
      {kind === "numeric" ? (
        <div className="grid gap-3">
          <label className="flex items-center gap-2 text-sm text-slate-700">
            <input
              type="checkbox"
              checked={rule.onlyPositive ?? false}
              onChange={(e) => onChange({ onlyPositive: e.target.checked || null })}
              className="rounded border-slate-300 text-sky-600 focus:ring-sky-500"
            />
            Sólo admite números positivos (rechaza ≤ 0)
          </label>
          <label className="flex items-center gap-2 text-sm text-slate-700">
            <input
              type="checkbox"
              checked={rule.allowDecimals === false}
              onChange={(e) => onChange({ allowDecimals: e.target.checked ? false : null })}
              className="rounded border-slate-300 text-sky-600 focus:ring-sky-500"
            />
            No admite cifras decimales
          </label>
          <label className="block text-sm">
            <span className="mb-1 block font-medium text-slate-700">
              Máximo de cifras significativas
            </span>
            <input
              type="number"
              min={1}
              value={rule.maxDigits ?? ""}
              onChange={(e) => onChange({ maxDigits: numberOrNull(e.target.value) })}
              placeholder="Sin límite"
              className="w-full rounded border border-slate-300 bg-white px-2 py-1 text-sm outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
            />
          </label>
        </div>
      ) : (
        <div className="grid gap-3">
          <label className="flex items-center gap-2 text-sm text-slate-700">
            <input
              type="checkbox"
              checked={rule.numericText ?? false}
              onChange={(e) => onChange({ numericText: e.target.checked || null })}
              className="rounded border-slate-300 text-sky-600 focus:ring-sky-500"
            />
            El texto debe ser enteramente numérico (sólo dígitos)
          </label>
          <div className="grid grid-cols-2 gap-3">
            <label className="block text-sm">
              <span className="mb-1 block font-medium text-slate-700">Mínimo de caracteres</span>
              <input
                type="number"
                min={0}
                value={rule.minLength ?? ""}
                onChange={(e) => onChange({ minLength: numberOrNull(e.target.value) })}
                placeholder="Sin mínimo"
                className="w-full rounded border border-slate-300 bg-white px-2 py-1 text-sm outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
              />
            </label>
            <label className="block text-sm">
              <span className="mb-1 block font-medium text-slate-700">Máximo de caracteres</span>
              <input
                type="number"
                min={1}
                value={rule.maxLength ?? ""}
                onChange={(e) => onChange({ maxLength: numberOrNull(e.target.value) })}
                placeholder="Sin máximo"
                className="w-full rounded border border-slate-300 bg-white px-2 py-1 text-sm outline-none focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
              />
            </label>
          </div>
        </div>
      )}
    </Modal>
  );
}
