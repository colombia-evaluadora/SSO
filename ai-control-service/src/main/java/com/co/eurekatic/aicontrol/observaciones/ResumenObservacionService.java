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
 * <p>El texto del modelo se guarda como BORRADOR ({@code ES_BORRADOR = "S"}):
 * no sale en el boletin hasta que un humano lo guarde desde la pantalla, y
 * ahi la base deduce APROBADA (sin cambios) o MODIFICADA (editado). Se guarda
 * por el mismo endpoint que la pantalla para que apliquen las mismas reglas
 * (gate, periodo cerrado); sus 4xx se propagan con el mensaje de la base.
 */
@Service
public class ResumenObservacionService {

    static final String ESTADO_BORRADOR = "BORRADOR";

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
        guardar.put("ES_BORRADOR", "S");
        queryService.post(tipo.rutaGuardar(), bearer, guardar);

        return new ResumenResponse(texto, fuentes.piezas().size(), ESTADO_BORRADOR, g.modelo(),
                g.tokensEntrada(), g.tokensSalida(), (System.nanoTime() - inicio) / 1_000_000, g.desdeCache());
    }
}
