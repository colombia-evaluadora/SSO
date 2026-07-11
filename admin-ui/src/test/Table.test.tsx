import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { Table, type Column } from "@/components/ui/Table";

interface User {
  id: number;
  name: string;
}

const columns: Column<User>[] = [
  { key: "id", header: "ID", render: (u) => u.id, align: "right" },
  { key: "name", header: "Name", render: (u) => u.name },
];

describe("Table", () => {
  it("renders a row per item", () => {
    render(
      <Table
        columns={columns}
        rows={[
          { id: 1, name: "Ana" },
          { id: 2, name: "Beto" },
        ]}
        rowKey={(u) => u.id}
      />,
    );
    expect(screen.getByText("Ana")).toBeInTheDocument();
    expect(screen.getByText("Beto")).toBeInTheDocument();
    expect(screen.getByText("2")).toBeInTheDocument();
  });

  it("shows an empty state when there are no rows", () => {
    render(<Table columns={columns} rows={[]} rowKey={(u) => u.id} />);
    expect(screen.getByText(/Sin resultados/i)).toBeInTheDocument();
  });

  it("shows a custom empty message", () => {
    render(
      <Table
        columns={columns}
        rows={[]}
        rowKey={(u) => u.id}
        empty="Aún no hay usuarios"
      />,
    );
    expect(screen.getByText(/Aún no hay usuarios/)).toBeInTheDocument();
  });

  it("shows the loading state when loading and there are no rows", () => {
    render(
      <Table columns={columns} rows={[]} rowKey={(u) => u.id} loading />,
    );
    expect(screen.getByRole("status")).toHaveTextContent(/Cargando/i);
  });
});
