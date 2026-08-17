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
 * <p>Un nombre de campo con puntos anida: {@code "usuario.email"} crea
 * (o reutiliza) un objeto {@code usuario} y le pone {@code email}
 * dentro. Hace falta cuando el destino no es una query del catálogo
 * sino un controller normal con un DTO anidado — por ejemplo
 * {@code auth-center POST /register/funcionario}, cuyo
 * {@code RegisterFuncionarioRequest} espera
 * {@code {"usuario": {..., "fkTarchivoFoto": 13}, "fkTmunicipioExpedicion": 1}}
 * y no un objeto plano. Un campo sin punto se comporta exactamente
 * como antes — queda en el primer nivel.
 *
 * <p><b>Esta clase no sabe nada de negocio.</b> No conoce funcionarios
 * ni establecimientos ni matrículas. Su única regla es "sube, sustituye
 * y anida según el nombre del campo", así que una operación nueva del
 * catálogo (o un DTO anidado en cualquier otro servicio) no le añade ni
 * una línea de código. Ésa es la propiedad que hace que el diseño
 * escale: la lógica de dónde va cada id vive en quien recibe el JSON
 * (PL/pgSQL o un @RequestBody), no aquí.
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
     * Resultado de la transformación: el cuerpo a reenviar y los ids
     * de las filas reservadas en esta petición.
     *
     * <p>Los ids salen a la superficie porque las filas quedan en
     * {@code active = false} hasta que el catálogo confirma la
     * operación, y quien ve esa confirmación es
     * {@code ReenvioController} — ver {@code ArchivoRepository#activar}.
     */
    public record Resultado(Map<String, Object> cuerpo, List<Long> archivoIds) {}

    /**
     * @param campos  partes de texto del multipart, tal cual llegaron
     * @param ficheros partes binarias, agrupadas por nombre de campo
     * @param usuario  identidad verificada del llamante, para auditoría
     * @return el cuerpo JSON a reenviar y los ids reservados
     */
    public Resultado transformar(Map<String, String> campos,
                                 Map<String, List<MultipartFile>> ficheros,
                                 String usuario) {
        Map<String, Object> cuerpo = new LinkedHashMap<>();
        campos.forEach((campo, valor) -> putAnidado(cuerpo, campo, valor));
        // Ids ya reservados, para poder deshacerlos si algo falla a
        // media transformación.
        List<Long> reservados = new ArrayList<>();
        // Subconjunto de `reservados` cuyo objeto SÍ llegó a subirse a
        // S3 (pk -> clave) — ver el porqué en `deshacer`.
        Map<Long, String> objetosSubidos = new LinkedHashMap<>();

        try {
            for (var entrada : ficheros.entrySet()) {
                String campo = entrada.getKey();
                List<MultipartFile> partes = entrada.getValue();
                List<Long> ids = new ArrayList<>(partes.size());

                for (MultipartFile parte : partes) {
                    if (parte.isEmpty()) {
                        continue;
                    }
                    ids.add(subirUna(parte, usuario, reservados, objetosSubidos));
                }
                if (ids.isEmpty()) {
                    continue;
                }
                // Un solo fichero en el campo → id suelto.
                // Varios → lista, que es lo que el JSON del cliente
                // sugería al repetir el mismo nombre de campo.
                putAnidado(cuerpo, campo, ids.size() == 1 ? ids.get(0) : ids);
            }
            return new Resultado(cuerpo, List.copyOf(reservados));

        } catch (RuntimeException | IOException e) {
            deshacer(reservados, objetosSubidos);
            throw new SubidaFallidaException(
                    "No se pudo procesar el multipart: " + e.getMessage(), e);
        }
    }

    /**
     * Escribe {@code valor} en {@code raiz} bajo la ruta que marca
     * {@code clave} partida por {@code "."} — {@code "usuario.email"}
     * crea (o reutiliza) un objeto {@code usuario} y le pone
     * {@code email} dentro. Sin punto, {@code clave} queda tal cual en
     * el primer nivel: mismo comportamiento que antes de que existiera
     * el anidado.
     *
     * <p>Si un segmento intermedio ya tiene un valor que no es un
     * objeto (choque de nombres, p. ej. {@code "usuario"} y
     * {@code "usuario.email"} en el mismo multipart), se pisa con un
     * objeto nuevo: quien arma el multipart eligió los nombres de
     * campo, así que un choque es un error de quien llama, no algo que
     * este método deba detectar — igual que el resto de la clase, no
     * valida significado de negocio.
     */
    @SuppressWarnings("unchecked")
    private static void putAnidado(Map<String, Object> raiz, String clave, Object valor) {
        String[] partes = clave.split("\\.");
        Map<String, Object> actual = raiz;
        for (int i = 0; i < partes.length - 1; i++) {
            Object existente = actual.get(partes[i]);
            if (existente instanceof Map) {
                actual = (Map<String, Object>) existente;
            } else {
                Map<String, Object> nuevo = new LinkedHashMap<>();
                actual.put(partes[i], nuevo);
                actual = nuevo;
            }
        }
        actual.put(partes[partes.length - 1], valor);
    }

    /**
     * Deshace lo reservado en esta petición. Sin esto, un fallo en el
     * tercer fichero dejaría los dos primeros registrados y sin dueño.
     *
     * <p><b>El orden importa</b>: S3 primero, filas después. Un fichero
     * de {@code objetosSubidos} ya tiene sus bytes en el bucket — si
     * sólo se borrara la fila (como hacía esto antes), el objeto
     * quedaría huérfano: invisible, sin ninguna fila que lo referencie,
     * facturándose indefinidamente, exactamente el escenario que
     * {@link ArchivoRepository#reservar} documenta como el que el
     * diseño "reservar antes de subir" existe para evitar — sólo que
     * aquí el objeto SÍ llegó a existir antes de que la petición
     * completa fallara por un fichero posterior. Con 408 000 objetos
     * en el bucket, esa clase de fuga no se detecta comparando el
     * bucket contra la tabla a mano.
     *
     * <p>Si el borrado en S3 falla (recorte de red al almacén, etc.),
     * se loguea a ERROR y se sigue con la fila igual — no se puede
     * dejar la fila (que el cliente podría reintentar y reservar de
     * nuevo) esperando a que S3 responda; mejor un objeto huérfano
     * detectable por el log que una petición que nunca termina de
     * fallar.
     */
    private void deshacer(List<Long> reservados, Map<Long, String> objetosSubidos) {
        for (var entrada : objetosSubidos.entrySet()) {
            try {
                almacen.borrar(entrada.getValue());
            } catch (RuntimeException ex) {
                log.error("rollback de subida fallida: no se pudo borrar el objeto "
                        + "huérfano pk_tarchivo={} clave={} — requiere limpieza manual",
                        entrada.getKey(), entrada.getValue(), ex);
            }
        }
        for (Long pk : reservados) {
            archivos.descartar(pk);
        }
    }

    private long subirUna(MultipartFile parte, String usuario, List<Long> reservados,
                          Map<Long, String> objetosSubidos) throws IOException {
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
            // A partir de aquí el objeto YA existe en el bucket — si
            // un fichero POSTERIOR de este mismo multipart falla, el
            // rollback de `deshacer` tiene que borrar este objeto
            // también, no sólo la fila. Por eso se registra ANTES de
            // registrarUrl: si registrarUrl fallara (subida a S3 bien,
            // UPDATE de la fila mal), el objeto también quedaría
            // huérfano si no estuviera aquí.
            objetosSubidos.put(pk, clave);
            // 3. Cerrar la fila con su URL. Sigue inactiva: la activa
            //    ReenvioController cuando el catálogo responde 2xx,
            //    que es el momento en que la operación de negocio
            //    completa se sabe terminada. Ver
            //    ArchivoRepository#activar.
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
