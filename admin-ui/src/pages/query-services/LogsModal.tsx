import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { Modal } from "@/components/ui/Modal";
import {
  useQueryServiceLogs,
} from "@/hooks/useQueryServices";
import type { MicroserviceResponse } from "@/api/types";

interface Props {
  microservice: MicroserviceResponse | null;
  onClose: () => void;
}

/**
 * Modal showing the last N lines of a query-service container's
 * stdout+stderr. The provisioner proxies to Docker's
 * `/containers/{name}/logs?tail=N&stdout=true&stderr=true`
 * (via sso-admin so the browser never reaches the sidecar
 * directly).
 *
 * The log body is rendered in a fixed-height monospace block
 * with a "Refresh" button and a "Copy" button. We use
 * `whitespace-pre-wrap` so multi-line stack traces and JSON
 * payloads survive intact; the line-number gutter is a
 * left-aligned "01 02 03 …" column for grep-ability.
 *
 * Auto-refresh is OFF by default — operators want stable text
 * when they're reading a trace. The Refresh button invalidates
 * the TanStack Query cache which re-fetches.
 */
const TAIL_OPTIONS = [100, 200, 500, 1000] as const;

export function LogsModal({ microservice, onClose }: Props) {
  const [tail, setTail] = useState<number>(200);
  const id = microservice?.id ?? null;
  const logs = useQueryServiceLogs(id, tail);

  return (
    <Modal
      open={microservice !== null}
      onClose={onClose}
      title={
        microservice
          ? `Logs — query-service-${microservice.instanceName ?? microservice.serviceId}`
          : "Logs"
      }
      {...(microservice
        ? { description: `Últimas ${tail} líneas (stdout+stderr) del contenedor` }
        : {})}
      size="lg"
      footer={
        <>
          <select
            value={tail}
            onChange={(e) => setTail(Number(e.target.value))}
            className="rounded border border-slate-300 bg-white px-2 py-1 text-sm text-slate-900"
            aria-label="Número de líneas"
          >
            {TAIL_OPTIONS.map((n) => (
              <option key={n} value={n}>{n} líneas</option>
            ))}
          </select>
          <Button
            variant="secondary"
            onClick={() => void logs.refetch()}
            loading={logs.isFetching}
          >
            Refrescar
          </Button>
          <Button
            variant="secondary"
            onClick={() => {
              if (logs.data) {
                void navigator.clipboard.writeText(logs.data);
              }
            }}
            disabled={!logs.data}
          >
            Copiar
          </Button>
          <Button onClick={onClose}>Cerrar</Button>
        </>
      }
    >
      <div className="rounded border border-slate-200 bg-slate-950 text-slate-100">
        {logs.isLoading ? (
          <div className="p-4 text-sm text-slate-400">Cargando logs…</div>
        ) : logs.isError ? (
          <div className="p-4 text-sm text-red-300">
            No se pudieron obtener los logs. ¿El provisioner está UP?
            <pre className="mt-2 whitespace-pre-wrap text-xs opacity-70">
              {(logs.error as Error)?.message}
            </pre>
          </div>
        ) : !logs.data ? (
          <div className="p-4 text-sm text-slate-400">Sin datos.</div>
        ) : (
          <pre
            className="max-h-[60vh] overflow-auto p-3 text-xs leading-relaxed"
            style={{ whiteSpace: "pre-wrap", wordBreak: "break-word" }}
            data-testid="logs-body"
          >
            {logs.data}
          </pre>
        )}
      </div>
    </Modal>
  );
}
