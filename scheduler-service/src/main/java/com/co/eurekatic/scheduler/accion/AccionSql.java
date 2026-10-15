package com.co.eurekatic.scheduler.accion;

import java.time.Duration;
import java.util.Map;
import javax.sql.DataSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Ejecuta una sentencia SQL en una transaccion. El servicio no conoce el
 * esquema: la sentencia llega de la configuracion, tipicamente un
 * {@code SELECT esquema.fn_algo()} que encapsula la regla de negocio.
 *
 * <pre>
 * parametros:
 *   sentencia: SELECT academico_test.fn_x()
 *   timeout: 5m                 # opcional, por defecto 5m
 *   ajustes:                    # opcional: set_config(k, v, true) antes
 *     app.user_id: scheduler    # de la sentencia (p. ej. atribucion CDC)
 * </pre>
 */
@Component
public class AccionSql implements Accion {

    private static final Duration TIMEOUT_POR_DEFECTO = Duration.ofMinutes(5);

    private final DataSource dataSource;
    private final TransactionTemplate transaccion;

    public AccionSql(DataSource dataSource, PlatformTransactionManager transactionManager) {
        this.dataSource = dataSource;
        this.transaccion = new TransactionTemplate(transactionManager);
    }

    @Override
    public String tipo() {
        return "sql";
    }

    @Override
    public void validar(Parametros parametros) {
        parametros.requerido("sentencia");
        parametros.duracion("timeout", TIMEOUT_POR_DEFECTO);
        parametros.mapa("ajustes");
    }

    @Override
    public void ejecutar(String tareaId, Parametros parametros) {
        String sentencia = parametros.requerido("sentencia");
        Map<String, String> ajustes = parametros.mapa("ajustes");

        JdbcTemplate jdbc = new JdbcTemplate(dataSource);
        jdbc.setQueryTimeout((int) parametros.duracion("timeout", TIMEOUT_POR_DEFECTO).toSeconds());

        transaccion.executeWithoutResult(estado -> {
            ajustes.forEach((clave, valor) ->
                    jdbc.queryForObject("SELECT set_config(?, ?, true)", String.class, clave, valor));
            jdbc.execute(sentencia);
        });
    }
}
