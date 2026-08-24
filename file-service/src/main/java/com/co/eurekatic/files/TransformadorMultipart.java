package com.co.eurekatic.files;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
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
    private final String sitio;

    public TransformadorMultipart(AlmacenObjetos almacen, ArchivoRepository archivos,
                                  @Value("${files.site-code:}") String sitio) {
        this.almacen = almacen;
        this.archivos = archivos;
        this.sitio = sitio;
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
     * @param idUser   {@code public.users.id_user} del llamante (claim
     *                 {@code uid} del JWT) — se puentea a
     *                 {@code academico_test.TUSUARIO.PK_TUSUARIO} para
     *                 {@code app.user_pk} (ver
     *                 {@code ArchivoRepository#applyAuditContext}).
     *                 {@code null} para tokens legado sin ese claim.
     * @param clasificaciones nombre de campo del multipart → clasificación
     *                 declarada ({@code "FILE:perfilUsuario"} en el
     *                 catálogo — ver {@code ParamTypes.FILE}). Sólo
     *                 trae entrada para los campos que la declararon;
     *                 un campo ausente de este mapa sigue el formato
     *                 de clave genérico de siempre. Puede venir vacío
     *                 o {@code null}.
     * @param establecimientos nombre de campo del multipart → código de
     *                 establecimiento YA VALIDADO por el llamante
     *                 (ver {@code FileDestinationAccessService}) contra
     *                 {@code testablecimiento.codigo}. Sólo trae
     *                 entrada para los campos cuya clasificación
     *                 declaró un tercer componente
     *                 ({@code "FILE:actividad:idEstablecimiento"}) — ver
     *                 {@code ParamTypes#parseDeclaration}. Esta clase
     *                 no valida nada, sólo usa el valor tal cual llega
     *                 como segmento literal de la clave S3 (ver
     *                 {@link #claveDe}) — la clasificación es lo único
     *                 que le importa a {@code file-service}, "qué es
     *                 un establecimiento" es de quien llama. Puede venir
     *                 vacío o {@code null}.
     * @return el cuerpo JSON a reenviar y los ids reservados
     */
    public Resultado transformar(Map<String, String> campos,
                                 Map<String, List<MultipartFile>> ficheros,
                                 String usuario,
                                 Long idUser,
                                 Map<String, String> clasificaciones,
                                 Map<String, String> establecimientos) {
        Map<String, Object> cuerpo = new LinkedHashMap<>();
        campos.forEach((campo, valor) -> putAnidado(cuerpo, campo, valor));
        // Ids ya reservados, para poder deshacerlos si algo falla a
        // media transformación.
        List<Long> reservados = new ArrayList<>();
        // Subconjunto de `reservados` cuyo objeto SÍ llegó a subirse a
        // S3 (pk -> clave) — ver el porqué en `deshacer`.
        Map<Long, String> objetosSubidos = new LinkedHashMap<>();
        Map<String, String> clasificacionesPorCampo =
                clasificaciones == null ? Map.of() : clasificaciones;
        Map<String, String> establecimientosPorCampo =
                establecimientos == null ? Map.of() : establecimientos;

        try {
            for (var entrada : ficheros.entrySet()) {
                String campo = entrada.getKey();
                List<MultipartFile> partes = entrada.getValue();
                List<Long> ids = new ArrayList<>(partes.size());
                String clasificacion = clasificacionesPorCampo.get(campo);
                String establecimiento = establecimientosPorCampo.get(campo);

                for (MultipartFile parte : partes) {
                    if (parte.isEmpty()) {
                        continue;
                    }
                    ids.add(subirUna(parte, usuario, idUser, clasificacion, establecimiento, reservados, objetosSubidos));
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
            deshacer(reservados, objetosSubidos, usuario, idUser);
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
    private void deshacer(List<Long> reservados, Map<Long, String> objetosSubidos, String usuario, Long idUser) {
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
            archivos.descartar(pk, usuario, idUser);
        }
    }

    private long subirUna(MultipartFile parte, String usuario, Long idUser, String clasificacion, String establecimiento,
                          List<Long> reservados, Map<Long, String> objetosSubidos) throws IOException {
        String nombre = nombreSeguro(parte.getOriginalFilename());
        long peso = parte.getSize();

        // 1. Reservar (active = false) — ver ArchivoRepository#reservar
        //    para por qué este orden y no al revés. Si el campo declaró
        //    clasificación (FILE:perfilUsuario), se guarda también en
        //    TARCHIVO.etiqueta — consistente con las filas históricas
        //    migradas, que siempre la traían.
        long pk = clasificacion == null
                ? archivos.reservar(nombre, peso, usuario, idUser)
                : archivos.reservar(nombre, peso, usuario, idUser, clasificacion);
        reservados.add(pk);

        // 2. La clave incluye el pk, así que es única sin necesidad de
        //    consultar el bucket, y permite rastrear un objeto hasta su
        //    fila con sólo mirar el nombre.
        //
        //    Con clasificación declarada, se imita el layout de las
        //    filas históricas migradas (.../perfilUsuario/141906.jpeg):
        //    <clasificacion>/<pk>.<extensión>. Sin clasificación (o sin
        //    extensión reconocible en el nombre — un campo puede llegar
        //    sin punto), se mantiene el formato genérico de siempre.
        String clave = claveDe(pk, nombre, clasificacion, sitio, establecimiento);

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
            archivos.registrarUrl(pk, url, usuario, idUser);
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

    /**
     * V63 — arma la clave S3 del objeto. Sin clasificación, el formato
     * de siempre: {@code <pk>/<nombreSeguro>} (único sin consultar el
     * bucket, rastreable a su fila con sólo mirar el nombre). Con
     * clasificación declarada en el catálogo ({@code FILE:perfilUsuario}),
     * imita el layout de las filas históricas migradas:
     * {@code <clasificacion>/<pk>.<extensión>}.
     *
     * <p>Si no hay extensión reconocible en {@code nombreSeguro}
     * (puede pasar: un campo sin nombre de archivo cae a un UUID sin
     * punto), no hay forma de armar {@code pk.extensión} con sentido
     * — se cae al formato genérico en vez de producir una clave con
     * un punto colgando.
     *
     * <p>V64 — {@code sitio} (config {@code files.site-code}, p.ej.
     * {@code "ACADEMICO_VALLEDUPAR"}) se antepone a lo anterior si
     * viene configurado: las filas históricas migradas casi siempre
     * traen ese código de sede como primer segmento
     * ({@code ACADEMICO_VALLEDUPAR/perfilUsuario/141906.jpeg}), algo
     * que file-service no puede reconstruir por su cuenta — no tiene
     * ningún concepto de "sede" en el flujo de subida, así que es
     * una constante de despliegue (una instalación de file-service
     * sirve UNA sola sede), igual que {@code files.schema}. Vacío
     * (el default) = sin prefijo, exactamente el comportamiento de
     * antes de que existiera esta config.
     *
     * <p>V65 — {@code establecimiento} (código YA VALIDADO por
     * {@code FileDestinationAccessService} contra
     * {@code testablecimiento.codigo}, resuelto por
     * {@code ReenvioController} desde el campo de texto que la
     * clasificación declaró — ver {@code ParamTypes#parseDeclaration})
     * va DESPUÉS del sitio y ANTES de la clasificación, imitando el
     * layout de las clasificaciones históricas que sí lo llevan
     * ({@code ACADEMICO_VALLEDUPAR/120001003751/actividad/...} — ver
     * {@code ParamTypes.ESTABLISHMENT_SCOPED_FILE_CLASSIFICATIONS}).
     * {@code null} (clasificación sin campo de establecimiento
     * declarado, o sin clasificación) = sin ese segmento, igual que
     * antes de V65. No tiene efecto si {@code clasificacion} es
     * {@code null}: sin carpeta de clasificación tampoco hay carpeta
     * de establecimiento — sería un segmento suelto sin el resto del
     * layout que le da sentido.
     */
    static String claveDe(long pk, String nombreSeguro, String clasificacion, String sitio,
                          String establecimiento) {
        String prefijo = (sitio == null || sitio.isBlank()) ? "" : sitio + "/";
        if (clasificacion == null) {
            return "%s%d/%s".formatted(prefijo, pk, nombreSeguro);
        }
        if (establecimiento != null && !establecimiento.isBlank()) {
            prefijo = prefijo + establecimiento + "/";
        }
        String extension = extensionDe(nombreSeguro);
        return extension == null
                ? "%s%d/%s".formatted(prefijo, pk, nombreSeguro)
                : "%s%s/%d.%s".formatted(prefijo, clasificacion, pk, extension);
    }

    private static String extensionDe(String nombreSeguro) {
        int punto = nombreSeguro.lastIndexOf('.');
        if (punto < 0 || punto == nombreSeguro.length() - 1) {
            return null;
        }
        return nombreSeguro.substring(punto + 1).toLowerCase(java.util.Locale.ROOT);
    }

    /** Fallo de subida, mapeado a 502 por el manejador global. */
    public static class SubidaFallidaException extends RuntimeException {
        public SubidaFallidaException(String mensaje, Throwable causa) {
            super(mensaje, causa);
        }
    }
}
