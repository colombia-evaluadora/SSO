import { Outlet } from "react-router-dom";
import { Topbar } from "@/layout/Topbar";
import { Sidebar } from "@/layout/Sidebar";

/**
 * Layout shell rendered inside <RequireAuth>. Topbar (user +
 * logout), sidebar (nav), and a main content area for the routed
 * page.
 */
export function App() {
  return (
    <div className="flex min-h-screen flex-col bg-slate-50">
      <Topbar />
      <div className="flex flex-1">
        <Sidebar />
        <main className="flex-1 px-6 py-6">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
