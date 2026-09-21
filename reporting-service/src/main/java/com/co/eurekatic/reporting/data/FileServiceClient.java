package com.co.eurekatic.reporting.data;

import com.co.eurekatic.reporting.config.ReportingProperties;
import com.co.eurekatic.reporting.render.Imagenes;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.client.ClientHttpRequestFactory;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.time.Duration;
import java.util.HashMap;
import java.util.Map;

/**
 * Baja de file-service los bytes de un archivo, dado su {@code PK_TARCHIVO}.
 *
 * <p>Es el espejo de {@link QueryServiceClient} — misma forma de construir el
 * cliente, mismos timeouts explicitos — pero con una diferencia que conviene
 * entender antes de copiarla a otro sitio: <b>no reenvia el token del
 * usuario</b>, se autentica con el secreto compartido {@code X-Internal-Token}
 * que {@code DownloadController} ya acepta.
 *
 * <p>El motivo es que {@code FileAccessService.puedeVer} solo reconoce como
 * propias las fotos de perfil y los soportes de actividad. La foto de una
 * matricula y el fondo del establecimiento no entran en ninguna de esas dos
 * categorias, asi que con el token del usuario darian 404 y el boletin saldria
 * mudo, sin imagenes y sin error — el peor de los fallos posibles.
 *
 * <p>Que no lleve identidad NO abre un agujero: la autorizacion ya ocurrio una
 * capa antes. La funcion PL/pgSQL aplico el gate de INFORMES con alcance
 * territorial y solo devolvio los estudiantes que ese usuario alcanza, de modo
 * que los unicos pk que llegan aqui son los de esas filas. Este cliente no
 * acepta un pk que venga de otro lado.
 */
@Component
public class FileServiceClient {

    private static final Logger log = LoggerFactory.getLogger(FileServiceClient.class);

    private final RestClient cliente;
    private final String tokenInterno;
    private final int maxBytes;

    public FileServiceClient(ReportingProperties props) {
        // Timeouts explicitos: el default de la fabrica simple es "sin
        // limite", y una imagen que no llega nunca dejaria el reporte colgado.
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout((int) Duration.ofSeconds(5).toMillis());
        factory.setReadTimeout((int) props.getFileRequestTimeout().toMillis());

        this.cliente = RestClient.builder()
                .baseUrl(props.getFileServiceBaseUrl())
                .requestFactory((ClientHttpRequestFactory) factory)
                .build();
        this.tokenInterno = props.getFileInternalToken();
        this.maxBytes = props.getMaxImageBytes();
    }

    /**
     * Una descarga por generacion de reporte, con memoria de lo ya pedido.
     *
     * <p>Existe porque el fondo institucional es el mismo en las 40 paginas de
     * un grupo: sin esto se bajaria 40 veces. Se crea uno por reporte y se
     * tira al terminar, para que la vida de los bytes en memoria sea la del
     * PDF y no la del proceso.
     */
    public Sesion nuevaSesion() {
        return new Sesion();
    }

    /** Descargas de un solo reporte. No es thread-safe a proposito: un reporte se genera en un hilo. */
    public final class Sesion implements Imagenes {

        private final Map<Long, byte[]> cache = new HashMap<>();

        /**
         * Los bytes del archivo, o {@code null} si no se pudo traer.
         *
         * <p>Devolver null en vez de propagar es deliberado: una foto que
         * falta no puede tumbar el boletin de un curso entero. El hueco se
         * pinta vacio y queda el WARN para diagnosticarlo.
         */
        @Override
        public byte[] bytes(Long pkTarchivo) {
            if (pkTarchivo == null) {
                return null;
            }
            // containsKey y no getOrDefault: un fallo anterior se cachea como
            // null, para no reintentar 40 veces la misma descarga rota.
            if (cache.containsKey(pkTarchivo)) {
                return cache.get(pkTarchivo);
            }
            byte[] datos = descargar(pkTarchivo);
            cache.put(pkTarchivo, datos);
            return datos;
        }
    }

    private byte[] descargar(long pkTarchivo) {
        if (tokenInterno == null || tokenInterno.isBlank()) {
            // Sin secreto la puerta interna de file-service esta cerrada y
            // todas las descargas darian 401. Se dice una vez y claro, en vez
            // de dejar un rastro de 401 que nadie relaciona con la config.
            log.warn("No hay reporting.file-internal-token configurado: el reporte saldra sin imagenes");
            return null;
        }
        try {
            byte[] datos = cliente.get()
                    .uri("/files/download/{id}", pkTarchivo)
                    .header("X-Internal-Token", tokenInterno)
                    .retrieve()
                    .body(byte[].class);

            if (datos == null || datos.length == 0) {
                log.warn("El archivo {} vino vacio", pkTarchivo);
                return null;
            }
            if (datos.length > maxBytes) {
                // El PDF se exporta entero en memoria, asi que una imagen
                // desmedida multiplicada por las paginas del grupo es un OOM.
                // Se descarta esa imagen, no el reporte.
                log.warn("El archivo {} pesa {} bytes y el maximo por imagen es {}: se omite",
                        pkTarchivo, datos.length, maxBytes);
                return null;
            }
            return datos;
        } catch (Exception e) {
            log.warn("No se pudo descargar el archivo {}: {}", pkTarchivo, e.toString());
            return null;
        }
    }
}
