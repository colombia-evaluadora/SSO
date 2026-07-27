import { PASSWORD_RULES } from "./passwordPolicy";

/**
 * Lista de requisitos de la contraseña que se marcan en vivo
 * mientras la persona escribe.
 *
 * <p>Se muestra siempre, no sólo cuando algo falla: si la regla
 * aparece únicamente al equivocarse, el usuario elige una
 * contraseña a ciegas y la corrige a base de rechazos. Enseñarla
 * desde el principio convierte cinco intentos en uno.
 *
 * <p>Antes de escribir nada (`password` vacío) los ítems se ven
 * neutros en vez de en rojo: nadie ha fallado todavía, y una lista
 * de errores en un formulario recién abierto se lee como un
 * reproche.
 */
export function PasswordRequirements({ password }: { password: string }) {
  const untouched = password.length === 0;

  return (
    <ul aria-label="Requisitos de la contraseña" className="mb-4 space-y-1">
      {PASSWORD_RULES.map((rule) => {
        const met = rule.test(password);
        return (
          <li
            key={rule.id}
            data-testid={`password-rule-${rule.id}`}
            // aria-checked sobre role=listitem no es válido, así que
            // el estado va también en el texto accesible: un lector
            // de pantalla no puede leer el color ni el icono.
            className={`flex items-start gap-2 text-xs ${
              untouched
                ? "text-slate-500"
                : met
                  ? "text-emerald-700"
                  : "text-slate-600"
            }`}
          >
            <span aria-hidden="true" className="mt-px font-semibold">
              {untouched ? "•" : met ? "✓" : "○"}
            </span>
            <span>
              {rule.label}
              <span className="sr-only">
                {untouched ? "" : met ? " (cumplido)" : " (pendiente)"}
              </span>
            </span>
          </li>
        );
      })}
    </ul>
  );
}
