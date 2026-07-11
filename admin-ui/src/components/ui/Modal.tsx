import { useEffect, useRef, type ReactNode } from "react";

/**
 * Modal dialog. Closes on Escape, traps focus on the panel,
 * restores focus to the previously focused element on unmount.
 * Backdrop click closes unless {@link dismissible} is false.
 *
 * Implemented with <dialog> for free top-layer, focus trap, and
 * backdrop styling. We open it imperatively with showModal() on
 * mount because React's declarative `open` prop on <dialog> uses
 * the non-modal form.
 */
export interface ModalProps {
  open: boolean;
  onClose: () => void;
  title: string;
  description?: string;
  children: ReactNode;
  footer?: ReactNode;
  dismissible?: boolean;
  size?: "sm" | "md" | "lg";
}

const sizeClasses = {
  sm: "max-w-sm",
  md: "max-w-md",
  lg: "max-w-2xl",
};

export function Modal({
  open,
  onClose,
  title,
  description,
  children,
  footer,
  dismissible = true,
  size = "md",
}: ModalProps) {
  const ref = useRef<HTMLDialogElement | null>(null);
  const previouslyFocused = useRef<HTMLElement | null>(null);

  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;

    if (open) {
      previouslyFocused.current =
        document.activeElement instanceof HTMLElement
          ? document.activeElement
          : null;
      if (!dialog.open) dialog.showModal();
    } else {
      if (dialog.open) dialog.close();
      previouslyFocused.current?.focus();
    }
  }, [open]);

  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    function onCancel(e: Event) {
      if (!dismissible) {
        e.preventDefault();
        return;
      }
      e.preventDefault();
      onClose();
    }
    function onBackdropClick(e: MouseEvent) {
      if (!dismissible) return;
      // <dialog> with showModal() treats clicks outside the panel
      // as a "click on the backdrop"; we close in that case.
      if (e.target === dialog) onClose();
    }
    dialog.addEventListener("cancel", onCancel);
    dialog.addEventListener("click", onBackdropClick);
    return () => {
      dialog.removeEventListener("cancel", onCancel);
      dialog.removeEventListener("click", onBackdropClick);
    };
  }, [dismissible, onClose]);

  return (
    <dialog
      ref={ref}
      aria-labelledby="modal-title"
      aria-describedby={description ? "modal-description" : undefined}
      className={[
        "rounded-lg border border-slate-200 bg-white p-0 shadow-xl",
        "backdrop:bg-slate-900/40",
        sizeClasses[size],
      ].join(" ")}
    >
      <div className="p-5">
        <h2 id="modal-title" className="text-base font-semibold text-slate-900">
          {title}
        </h2>
        {description ? (
          <p id="modal-description" className="mt-1 text-sm text-slate-500">
            {description}
          </p>
        ) : null}
        <div className="mt-4">{children}</div>
      </div>
      {footer ? (
        <div className="flex justify-end gap-2 border-t border-slate-100 bg-slate-50 px-5 py-3">
          {footer}
        </div>
      ) : null}
    </dialog>
  );
}
