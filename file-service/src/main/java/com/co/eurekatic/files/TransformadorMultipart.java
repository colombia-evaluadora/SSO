package com.co.eurekatic.files;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Convierte un multipart en el JSON que espera el catálogo: cada parte
 * binaria se sube y se sustituye por su id, <b>conservando el nombre
 * del campo</b>.
 *
 * <pre>
 *   multipart                 →   JSON reenviado
 *   ─────────────────────────     ────────────────────────
 *   nombre = "Juan Pérez"         { "nombre": "Juan Pérez",
 *   pdf    = &lt;binario&gt;              "pdf":    12,
 *   foto   = &lt;binario&gt;              "foto":   13 }
 * </pre>
 *
 * <p>Y el procedimiento del catálogo lo lee como {@code :BODY.PDF} y
 * {@code :BODY.FOTO}, decidiendo él en qué tabla y columna va cada uno.
 *
 * <p><b>Esta clase no sabe nada de negocio.</b> No conoce funcionarios
 * ni establecimientos ni matrículas. Su única regla es "sube y
 * sustituye", así que una operación nueva del catálogo no le añade ni
 * una línea de código. Ésa es la propiedad que hace que el diseño
 * escale: la lógica de dónde va cada id vive en el PL/pgSQL, que es
 * donde ya vive el resto de la lógica de datos.
 */
@Component
public class TransformadorMultipart {

    private static final Logger log = LoggerFactory.getLogger(TransformadorMultipart.class);

    private final AlmacenObjetos almacen;
    private final ArchivoRepository archivos;

    public TransformadorMultipart(AlmacenObjetos almacen, ArchivoRepository archivos) {
        this.almacen = almacen;
        this.archivos = archivos;
    }

    /**
     * @param campos  partes de texto del multipart, tal cual llegaron
     * @param ficheros partes binarias, agrupadas por nombre de campo
     * @param usuario  identidad verificada del llamante, para auditoría
     * @return el cuerpo JSON a reenviar
     */
    public Map<String, Object> transformar(Map<String, String> campos,
                                           Map<String, List<MultipartFile>> ficheros,
                                           String usuario) {
        Map<String, Object> cuerpo = new LinkedHashMap<>(campos);
        // Ids ya reservados, para poder deshacerlos si algo falla a
        // media transformación.
        List<Long> reservados = new ArrayList<>();

        try {
            for (var entrada : ficheros.entrySet()) {
                String campo = entrada.getKey();
                List<MultipartFile> partes = entrada.getValue();
                List<Long> ids = new ArrayList<>(partes.size());

                for (MultipartFile parte : partes) {
                    if (parte.isEmpty()) {
                        continue;
                    }
                    ids.add(subirUna(parte, usuario, reservados));
                }
                if (ids.isEmpty()) {
                    continue;
                }
                // Un solo fichero en el campo → id suelto.
                // Varios → lista, que es lo que el JSON del cliente
                // sugería al repetir el mismo nombre de campo.
                cuerpo.put(campo, ids.size() == 1 ? ids.get(0) : ids);
            }
            return cuerpo;

        } catch (RuntimeException | IOException e) {
            // Deshacer lo reservado en esta petición. Sin esto, un
            // fallo en el tercer fichero dejaría los dos primeros
            // registrados y sin dueño.
            for (Long pk : reservados) {
                archivos.descartar(pk);
            }
            throw new SubidaFallidaException(
                    "No se pudo procesar el multipart: " + e.getMessage(), e);
        }
    }

    private long subirUna(MultipartFile parte, String usuario, List<Long> reservados)
            throws IOException {
        String nombre = nombreSeguro(parte.getOriginalFilename());
        long peso = parte.getSize();

        // 1. Reservar (active = false) — ver ArchivoRepository#reservar
        //    para por qué este orden y no al revés.
        long pk = archivos.reservar(nombre, peso, usuario);
        reservados.add(pk);

        // 2. La clave incluye el pk, así que es única sin necesidad de
        //    consultar el bucket, y permite rastrear un objeto hasta su
        //    fila con sólo mirar el nombre.
        String clave = "%d/%s".formatted(pk, nombre);

        try (InputStream in = parte.getInputStream()) {
            String url = almacen.subir(clave, in, peso, parte.getContentType());
            // 3. Cerrar la fila. Sigue inactiva: la activa el
            //    procedimiento del catálogo cuando la operación de
            //    negocio completa termina bien.
            archivos.registrarUrl(pk, url);
        }
        log.debug("campo con fichero '{}' -> pk_tarchivo={}", nombre, pk);
        return pk;
    }

    /**
     * Nombre de fichero utilizable como clave de objeto.
     *
     * <p>El nombre lo elige quien sube, así que no puede ir a la clave
     * sin limpiar: {@code ../../algo} o una barra cualquiera cambian la
     * ruta del objeto dentro del bucket. Se queda sólo con el nombre
     * base y se restringe el juego de caracteres.
     */
    static String nombreSeguro(String original) {
        if (original == null || original.isBlank()) {
            return UUID.randomUUID().toString();
        }
        // Quedarse con el último segmento descarta cualquier intento de
        // recorrido de rutas, tanto con / como con \.
        String base = original.replace('\\', '/');
        base = base.substring(base.lastIndexOf('/') + 1);
        base = base.replaceAll("[^A-Za-z0-9._-]", "_");
        // Un nombre que quedara vacío o fuese sólo puntos volvería a ser
        // un recorrido de ruta encubierto.
        if (base.isBlank() || base.replace(".", "").isBlank()) {
            return UUID.randomUUID().toString();
        }
        return base.length() > 120 ? base.substring(base.length() - 120) : base;
    }

    /** Fallo de subida, mapeado a 502 por el manejador global. */
    public static class SubidaFallidaException extends RuntimeException {
        public SubidaFallidaException(String mensaje, Throwable causa) {
            super(mensaje, causa);
        }
    }
}
