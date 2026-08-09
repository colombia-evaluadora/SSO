import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { filesApi } from "@/api/endpoints";

/**
 * Claves de caché para los binarios de TARCHIVO.
 *
 * <p>El contenido de un archivo no cambia: la clave S3 lleva el
 * {@code pk_tarchivo} dentro, así que subir otro fichero produce
 * otra fila y otro id. Por eso el blob se puede cachear sin
 * invalidación — no hay mutación que lo deje obsoleto.
 */
export const archivoKeys = {
  all: ["archivo"] as const,
  blob: (id: number) => [...archivoKeys.all, "blob", id] as const,
};

/**
 * Descarga el binario de un archivo y devuelve una URL utilizable
 * en un {@code <img src>} o un {@code <a href>}.
 *
 * <p>Hace falta este rodeo porque el endpoint de descarga exige el
 * Bearer del usuario, y un {@code <img>} no puede poner cabeceras.
 * La única cookie del SSO es {@code sso_refresh} (HttpOnly,
 * SameSite=Strict), que sirve para renovar el token, no para
 * autorizar peticiones. Así que se descarga con fetch —el cliente
 * pone el Bearer y reintenta si el token había caducado— y se
 * envuelve el Blob en un object URL.
 *
 * <p>Pasar {@code null} desactiva la descarga; sirve para filas que
 * todavía no tienen archivo asociado.
 *
 * @example
 * const { url, isLoading, error } = useArchivoUrl(fila.archivo_id);
 * return url ? <img src={url} alt="Firma" /> : null;
 */
export function useArchivoUrl(archivoId: number | null | undefined) {
  const habilitado = typeof archivoId === "number" && archivoId > 0;

  const consulta = useQuery({
    queryKey: archivoKeys.blob(archivoId ?? 0),
    queryFn: () => filesApi.descargar(archivoId as number),
    enabled: habilitado,
    staleTime: Infinity,
    // Reintentar una descarga de 20 MB porque el servidor devolvió
    // 404 sólo gasta ancho de banda: si el archivo no está, no va a
    // aparecer entre reintentos.
    retry: false,
  });

  const blob = consulta.data;
  const [url, setUrl] = useState<string | null>(null);

  useEffect(() => {
    if (!blob) {
      setUrl(null);
      return;
    }
    // createObjectURL reserva memoria que el navegador NO libera al
    // desmontar el componente: hay que revocarla a mano. Sin esto,
    // una tabla que pinta 50 firmas y se recorre varias veces deja
    // 50 blobs vivos por recorrido. El cleanup corre también cuando
    // cambia el blob, no sólo al desmontar, así que la URL anterior
    // se libera antes de crear la nueva.
    const objectUrl = URL.createObjectURL(blob);
    setUrl(objectUrl);
    return () => {
      URL.revokeObjectURL(objectUrl);
      setUrl(null);
    };
  }, [blob]);

  return {
    url,
    isLoading: habilitado && consulta.isLoading,
    error: consulta.error,
  };
}
