package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.ssoadmin.dto.MicroserviceTestConnectionRequest;
import com.co.eurekatic.ssoadmin.dto.MicroserviceTestConnectionResponse;
import org.springframework.stereotype.Component;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;

/**
 * Sonda JDBC sin persistencia: abre una conexión con los parámetros
 * dados y ejecuta {@link Connection#isValid(int)} con timeout de 5s.
 * Dialect-agnostic — el driver decide cómo validar (Postgres hace una
 * consulta vacía interna; Oracle / SQLServer hacen el equivalente). No
 * se ejecuta SQL arbitrario: la sonda es del driver, no del usuario.
 *
 * <p>Por qué {@link DriverManager} y no un {@code DataSource} temporal:
 * para una validación one-shot abrir/cerrar sin pool es más simple. No
 * se necesitan conexiones concurrentes y el classpath runtime ya
 * incluye el driver (Postgres al menos; otros dialectos se cargan vía
 * SPI del JDK si están en el classpath del container).
 *
 * <p><b>Por qué es una clase aparte:</b> {@code DriverManager} es
 * estático y no se mockea con Mockito. Aislando la única llamada
 * estática en este componente, {@link MicroserviceService} queda
 * testeable — incluido el gate de conexión de {@code create(...)},
 * que si no obligaría a levantar una base real en un test unitario.
 *
 * <p>En éxito devuelve el record con la latencia en ms. En fallo lanza
 * {@link IllegalArgumentException}, que el {@code GlobalExceptionHandler}
 * mapea a 400 {@code INVALID_REQUEST} con cuerpo
 * {@code {code, message, timestamp}}.
 */
@Component
public class JdbcConnectionProbe {

    public MicroserviceTestConnectionResponse probe(MicroserviceTestConnectionRequest req) {
        if (req.jdbcUrl() == null || !req.jdbcUrl().startsWith("jdbc:")) {
            throw new IllegalArgumentException("jdbcUrl debe comenzar con 'jdbc:'");
        }
        long t0 = System.nanoTime();
        try (Connection c = DriverManager.getConnection(
                req.jdbcUrl(),
                req.dbUsername(),
                req.dbPassword() == null ? "" : req.dbPassword())) {
            if (!c.isValid(5)) {
                throw new IllegalArgumentException(
                        "La conexión se abrió pero el driver reportó inválida (timeout 5s)");
            }
            long ms = (System.nanoTime() - t0) / 1_000_000L;
            return MicroserviceTestConnectionResponse.success(req.dialect(), ms);
        } catch (SQLException e) {
            // Mensaje sanitizado: NO incluye la URL completa (puede
            // llevar credenciales embebidas vía ?user=...&password=...)
            // ni el password. El driver ya da un mensaje razonablemente
            // útil (e.g. "FATAL: password authentication failed for
            // user \"x\"").
            throw new IllegalArgumentException(
                    "No se pudo conectar: " + sanitize(e.getMessage()));
        }
    }

    /**
     * Recorta el mensaje del driver a una sola línea y a 240
     * caracteres. Protege la UI de payloads enormes (algunos
     * drivers apilan stack traces multi-línea) y mantiene
     * uniforme la longitud del toast/banner.
     */
    private static String sanitize(String msg) {
        if (msg == null) return "error desconocido del driver";
        int nl = msg.indexOf('\n');
        if (nl > 0) msg = msg.substring(0, nl);
        return msg.length() > 240 ? msg.substring(0, 240) + "…" : msg;
    }
}
