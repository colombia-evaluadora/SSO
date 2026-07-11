import { forwardRef, type ButtonHTMLAttributes, type ReactNode } from "react";

/**
 * Button. Variants: primary (sky), secondary (outline), danger (red),
 * ghost (no border). Sizes: sm, md. The component is intentionally
 * thin — all the visual work happens via Tailwind classes so we
 * don't ship any runtime CSS-in-JS.
 *
 * Loading state shows a small spinner and disables the button so
 * the user can't double-click and double-submit. `loading` is
 * separate from `disabled` so the latter can still mean "not
 * permitted" with a tooltip explaining why.
 */
export type ButtonVariant = "primary" | "secondary" | "danger" | "ghost";
export type ButtonSize = "sm" | "md";

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: ButtonSize;
  loading?: boolean;
  leftIcon?: ReactNode;
  rightIcon?: ReactNode;
}

const variantClasses: Record<ButtonVariant, string> = {
  primary:
    "bg-sky-600 text-white hover:bg-sky-700 disabled:bg-sky-300",
  secondary:
    "bg-white text-slate-700 border border-slate-300 hover:bg-slate-50 disabled:bg-slate-100 disabled:text-slate-400",
  danger:
    "bg-red-600 text-white hover:bg-red-700 disabled:bg-red-300",
  ghost:
    "bg-transparent text-slate-700 hover:bg-slate-100 disabled:text-slate-400",
};

const sizeClasses: Record<ButtonSize, string> = {
  sm: "px-2.5 py-1 text-xs",
  md: "px-3 py-2 text-sm",
};

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(
  function Button(
    {
      variant = "primary",
      size = "md",
      loading = false,
      disabled,
      leftIcon,
      rightIcon,
      children,
      className,
      type,
      ...rest
    },
    ref,
  ) {
    return (
      <button
        ref={ref}
        type={type ?? "button"}
        disabled={disabled || loading}
        className={[
          "inline-flex items-center justify-center gap-1.5 rounded font-medium",
          "transition-colors",
          "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sky-500 focus-visible:ring-offset-1",
          "disabled:cursor-not-allowed",
          variantClasses[variant],
          sizeClasses[size],
          className ?? "",
        ].join(" ")}
        {...rest}
      >
        {loading ? (
          <span
            aria-hidden="true"
            className="inline-block h-3.5 w-3.5 animate-spin rounded-full border-2 border-current border-r-transparent"
          />
        ) : leftIcon}
        {children}
        {!loading && rightIcon}
      </button>
    );
  },
);
