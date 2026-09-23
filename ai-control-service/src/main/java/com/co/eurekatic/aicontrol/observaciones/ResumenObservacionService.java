package com.co.eurekatic.aicontrol.observaciones;

import com.co.eurekatic.aicontrol.client.QueryServiceClient;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Fuentes, modelo y guardado de un resumen de observaciones.
 *
 * <p>Se guarda con {@code OBSERVACION = OBSERVACION_IA}: la base deduce el
 * estado comparando ambos, asi que el texto nace APROBADA y pasa a
 * MODIFICADA en cuanto el docente lo edite desde la pantalla.
 */
@Service
public class ResumenObservacionService {

    private final QueryServiceClient queryService;
    private final GeneradorResumen generador;

    public ResumenObservacionService(QueryServiceClient queryService, GeneradorResumen generador) {
        this.queryService = queryService;
        this.generador = generador;
    }

    public ResumenResponse generarYGuardar(TipoResumen tipo, Map<String, Object> llave,
                                           boolean sobrescribir, String bearer) {
        long inicio = System.nanoTime();

        List<Map<String, Object>> filas = queryService.post(tipo.rutaFuentes(), bearer, llave);
        Fuentes fuentes = Fuentes.desdeFilas(tipo, filas);
        if (fuentes.piezas().isEmpty()) {
            // La funcion ya responde 22023 sin fuentes; esto cubre una fila de
            // query mal configurada que devuelva vacio.
            throw new ResponseStatusException(HttpStatus.UNPROCESSABLE_CONTENT,
                    "No hay observaciones para resumir.");
        }
        // Se comprueba ANTES de llamar al modelo: si el docente ya reescribio
        // el texto, no se gasta cuota para despues negarse a guardarlo.
        if (fuentes.modificadaPorDocente() && !sobrescribir) {
            throw new ResponseStatusException(HttpStatus.CONFLICT,
                    "El resumen guardado fue modificado por el docente. Envíe SOBRESCRIBIR=true para reemplazarlo.");
        }

        GeneradorResumen.Generacion g = generador.generar(tipo, fuentes);
        String texto = Anonimizador.restaurar(g.texto(), fuentes.estudiante());

        Map<String, Object> guardar = new LinkedHashMap<>(llave);
        guardar.put("OBSERVACION", texto);
        guardar.put("OBSERVACION_IA", texto);
        guardar.put(tipo.campoOrigen(), fuentes.piezas().size());
        queryService.post(tipo.rutaGuardar(), bearer, guardar);

        return new ResumenResponse(texto, fuentes.piezas().size(), "APROBADA", g.modelo(),
                g.tokensEntrada(), g.tokensSalida(), (System.nanoTime() - inicio) / 1_000_000, g.desdeCache());
    }
}
