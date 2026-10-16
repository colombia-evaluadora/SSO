package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.nucleo.Faltante;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.AccionUi;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.seguridad.seudonimos.TablaSeudonimos;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Lleva una respuesta del agente entre sus dos formas: con seudonimos (la que se guarda en memoria e
 * historial y vuelve al modelo) y con los nombres reales (la que ve la persona). Cubre los textos y
 * tambien los valores que el modelo pone en acciones de UI y borradores, que pueden llevar un alias.
 */
final class SeudonimosRespuesta {

    private SeudonimosRespuesta() {
    }

    static RespuestaAgente ocultar(RespuestaAgente respuesta, TablaSeudonimos tabla) {
        return respuesta.transformarTextos(tabla::ocultar);
    }

    static RespuestaAgente revelar(RespuestaAgente respuesta, TablaSeudonimos tabla) {
        return switch (respuesta) {
            case RespuestaAgente.Ui ui -> new RespuestaAgente.Ui(tabla.revelar(ui.texto()),
                    ui.acciones().stream().map(a -> revelar(a, tabla)).toList());
            case RespuestaAgente.Pregunta p -> new RespuestaAgente.Pregunta(tabla.revelar(p.texto()),
                    p.faltantes().stream().map(f -> new Faltante(f.campo(), tabla.revelar(f.pregunta()),
                            f.opciones().stream().map(tabla::revelar).toList())).toList(),
                    valores(p.borrador(), tabla));
            case RespuestaAgente.Respuesta r -> r.transformarTextos(tabla::revelar);
            case RespuestaAgente.Confirmacion c -> c.transformarTextos(tabla::revelar);
            case RespuestaAgente.Datos d -> d.transformarTextos(tabla::revelar);
            case RespuestaAgente.Bloqueado b -> b;
            case RespuestaAgente.SinPermiso s -> s;
        };
    }

    private static AccionUi revelar(AccionUi accion, TablaSeudonimos tabla) {
        return switch (accion) {
            case AccionUi.Rellenar r -> new AccionUi.Rellenar(r.formulario(), valores(r.valores(), tabla));
            case AccionUi.AplicarFiltros f -> new AccionUi.AplicarFiltros(valores(f.filtros(), tabla));
            case AccionUi.Navegar n -> {
                Map<String, String> params = new LinkedHashMap<>();
                n.params().forEach((k, v) -> params.put(k, tabla.revelar(v)));
                yield new AccionUi.Navegar(n.pantalla(), n.url(), params);
            }
            case AccionUi.LimpiarCampo l -> l;
            case AccionUi.Resaltar r -> r;
            case AccionUi.AbrirPestana p -> p;
        };
    }

    private static Map<String, Object> valores(Map<String, Object> valores, TablaSeudonimos tabla) {
        Map<String, Object> reales = new LinkedHashMap<>();
        valores.forEach((k, v) -> reales.put(k, tabla.revelarValor(v)));
        return reales;
    }
}
