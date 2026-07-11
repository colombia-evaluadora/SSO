/**
 * Status badge for runtime container state. Maps the Docker
 * Engine API's state string into a Tailwind color + label.
 *
 * We accept the raw state (`running`, `exited`, `created`,
 * `paused`, `restarting`, `dead`, `removing`) plus three
 * synthetic values we surface from the API layer:
 *   - `provisioning` — the row exists in MICROSERVICE but
 *     sso-admin hasn't yet completed the round-trip
 *     (container create + Eureka registration). Yellow.
 *   - `unknown` — we couldn't reach the provisioner
 *     (sidecar down, network blip). Slate.
 *   - `absent` — the row exists but the container is gone
 *     (e.g. manually `docker rm`'d, or a previous delete
 *     raced a deprovision failure). Red.
 */

export type ContainerState =
  | "running"
  | "exited"
  | "created"
  | "paused"
  | "restarting"
  | "dead"
  | "removing"
  | "provisioning"
  | "unknown"
  | "absent";

const COLOR: Record<ContainerState, string> = {
  running: "bg-emerald-100 text-emerald-800",
  provisioning: "bg-amber-100 text-amber-800",
  exited: "bg-slate-200 text-slate-700",
  created: "bg-slate-100 text-slate-700",
  paused: "bg-sky-100 text-sky-800",
  restarting: "bg-amber-100 text-amber-800",
  dead: "bg-red-100 text-red-800",
  removing: "bg-slate-100 text-slate-700",
  unknown: "bg-slate-100 text-slate-600",
  absent: "bg-red-100 text-red-800",
};

const LABEL: Record<ContainerState, string> = {
  running: "UP",
  provisioning: "PROVISIONING",
  exited: "EXITED",
  created: "CREATED",
  paused: "PAUSED",
  restarting: "RESTARTING",
  dead: "DEAD",
  removing: "REMOVING",
  unknown: "UNKNOWN",
  absent: "ABSENT",
};

export interface StatusBadgeProps {
  state: ContainerState | string | null | undefined;
}

export function StatusBadge({ state }: StatusBadgeProps) {
  const normalized = (state ?? "unknown") as ContainerState;
  const tone = COLOR[normalized] ?? COLOR.unknown;
  const text = LABEL[normalized] ?? normalized.toUpperCase();
  return (
    <span
      className={[
        "inline-flex items-center rounded px-2 py-0.5 text-xs font-medium",
        tone,
      ].join(" ")}
      data-state={normalized}
    >
      {text}
    </span>
  );
}
