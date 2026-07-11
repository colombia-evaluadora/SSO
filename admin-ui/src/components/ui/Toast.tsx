import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";

/**
 * Lightweight toast. A provider renders a fixed-position stack in
 * the corner; consumers call {@link useToast}().show(msg, variant)
 * and the toast auto-dismisses after {@link durationMs}.
 *
 * We intentionally don't use a 3rd-party library (react-hot-toast,
 * sonner) — both add a few KB and a separate focus management
 * story we don't need for admin-y "saved!" feedback.
 */
export type ToastVariant = "info" | "success" | "error";

export interface ToastItem {
  id: number;
  message: string;
  variant: ToastVariant;
}

interface ToastContextValue {
  show: (message: string, variant?: ToastVariant) => void;
}

const ToastContext = createContext<ToastContextValue | null>(null);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([]);
  const idRef = useRef(0);

  const show = useCallback(
    (message: string, variant: ToastVariant = "info") => {
      const id = ++idRef.current;
      setItems((prev) => [...prev, { id, message, variant }]);
      window.setTimeout(() => {
        setItems((prev) => prev.filter((t) => t.id !== id));
      }, 4000);
    },
    [],
  );

  const value = useMemo(() => ({ show }), [show]);

  return (
    <ToastContext.Provider value={value}>
      {children}
      <div
        aria-live="polite"
        aria-atomic="true"
        className="pointer-events-none fixed bottom-4 right-4 z-50 flex w-80 flex-col gap-2"
      >
        {items.map((t) => (
          <div
            key={t.id}
            role={t.variant === "error" ? "alert" : "status"}
            className={[
              "pointer-events-auto rounded border px-3 py-2 text-sm shadow",
              t.variant === "success" && "border-emerald-200 bg-emerald-50 text-emerald-800",
              t.variant === "error" && "border-red-200 bg-red-50 text-red-800",
              t.variant === "info" && "border-slate-200 bg-white text-slate-800",
            ]
              .filter(Boolean)
              .join(" ")}
          >
            {t.message}
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}

export function useToast(): ToastContextValue {
  const ctx = useContext(ToastContext);
  if (!ctx) {
    // No provider? Fall back to console so we don't crash. Real
    // app wires ToastProvider around the router in main.tsx.
    return {
      show: (msg) => {
        // eslint-disable-next-line no-console
        console.warn(`[toast] ${msg}`);
      },
    };
  }
  return ctx;
}
