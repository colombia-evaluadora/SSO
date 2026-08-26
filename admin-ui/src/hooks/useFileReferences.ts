import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { fileReferencesApi } from "@/api/endpoints";
import { ApiError } from "@/api/client";
import type { FileReferenceLocationRequest } from "@/api/types";

export const fileReferenceKeys = {
  all: ["file-references"] as const,
  byPk: (pk: number) => [...fileReferenceKeys.all, pk] as const,
};

/**
 * Looks up one {@code pk_tarchivo}. {@code enabled} is false until
 * the operator actually searches — this is a lookup-by-id page, not
 * a list, so there's nothing to fetch on mount.
 *
 * <p>A 404 is a normal, expected outcome here (most of the time the
 * operator is here BECAUSE the row doesn't exist yet) — it resolves
 * to {@code null} instead of surfacing as {@code isError}, so the
 * page can render "sin referencia registrada" instead of an error
 * banner. Any other status still surfaces as a real query error.
 */
export function useFileReference(pk: number | null) {
  return useQuery({
    queryKey: pk == null ? fileReferenceKeys.byPk(-1) : fileReferenceKeys.byPk(pk),
    queryFn: async () => {
      try {
        return await fileReferencesApi.get(pk as number);
      } catch (e) {
        if (e instanceof ApiError && e.status === 404) {
          return null;
        }
        throw e;
      }
    },
    enabled: pk != null,
    retry: false,
  });
}

export function useUpsertFileReference() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ pk, body }: { pk: number; body: FileReferenceLocationRequest }) =>
      fileReferencesApi.upsert(pk, body),
    onSuccess: (_data, { pk }) => {
      void qc.invalidateQueries({ queryKey: fileReferenceKeys.byPk(pk) });
    },
  });
}
