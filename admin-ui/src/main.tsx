import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { AuthProvider } from "@/auth/AuthProvider";
import { router } from "@/router";
import { RouterProvider } from "react-router-dom";
import { ToastProvider } from "@/components/ui/Toast";
import "@/index.css";

/**
 * QueryClient. Defaults are tuned for an admin tool: data doesn't
 * change rapidly, so 5min staleTime keeps the network quiet. Retry
 * is disabled because most API errors are real and the user needs
 * to see them; we don't want a 4xx to trigger 3 retries and a 4-second
 * spinner.
 */
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 5 * 60 * 1000,
      gcTime: 30 * 60 * 1000,
      retry: false,
      refetchOnWindowFocus: false,
    },
    mutations: {
      retry: false,
    },
  },
});

const rootEl = document.getElementById("root");
if (!rootEl) throw new Error("Missing #root in index.html");

createRoot(rootEl).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        <AuthProvider>
          <RouterProvider router={router} />
        </AuthProvider>
      </ToastProvider>
    </QueryClientProvider>
  </StrictMode>,
);
