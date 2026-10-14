package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import com.co.eurekatic.aicontrol.agente.catalogo.esquema.NombresParametro;
import com.co.eurekatic.aicontrol.agente.persistencia.herramienta.EstadoInvocacion;
import com.co.eurekatic.aicontrol.agente.persistencia.herramienta.ToolInvocacionStore;
import com.co.eurekatic.aicontrol.client.QueryServiceClient;
import com.co.eurekatic.aicontrol.client.RespuestaQuery;
import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Ejecuta una herramienta del turno: valida, comprueba la regla de ids, llama a query-service con
 * el token del usuario (lecturas) o propone una accion pendiente (escrituras, que nunca se
 * ejecutan aqui). Cada llamada queda en {@code ai.tool_invocacion}.
 *
 * <p>Los errores no lanzan: vuelven como {@link ResultadoHerramienta.ErrorParaModelo} para que
 * el modelo los lea y corrija. Lo unico que lanza es un fallo de cableado.
 */
@Component
public class InvocadorHerramientas {

    private static final Logger log = LoggerFactory.getLogger(InvocadorHerramientas.class);
    private static final String ERROR_SERVIDOR =
            "El servicio academico no respondio. No reintentes esta herramienta en este turno.";

    private final QueryServiceClient queryService;
    private final VerificadorIds verificadorIds;
    private final RegistroIds registroIds;
    private final ToolInvocacionStore almacen;
    private final int maxFilas;
    private final FiltroColumnasSensibles filtro;
    private final CompletadorSesion completador;
    private final ValidadorArgumentos validador = new ValidadorArgumentos();

    public InvocadorHerramientas(QueryServiceClient queryService, VerificadorIds verificadorIds,
                                 RegistroIds registroIds, ToolInvocacionStore almacen, AgenteProperties props,
                                 CompletadorSesion completador) {
        this.queryService = queryService;
        this.verificadorIds = verificadorIds;
        this.registroIds = registroIds;
        this.almacen = almacen;
        this.maxFilas = props.catalogo().maxFilas();
        this.filtro = new FiltroColumnasSensibles(props.catalogo().columnasSensibles());
        this.completador = completador;
    }

    /**
     * @param herramienta herramienta de datos (LECTURA, ANALITICA o ESCRITURA)
     * @param argumentos  argumentos tal como los dejo el modelo
     * @param contexto    usuario, token, conversacion y canal de propuestas del turno
     */
    public ResultadoHerramienta invocar(HerramientaDef herramienta, Map<String, Object> argumentos,
                                        ContextoInvocacion contexto) {
        long inicio = System.nanoTime();
        Ejecucion ejecucion = ejecutar(herramienta, argumentos, contexto);
        long duracionMs = (System.nanoTime() - inicio) / 1_000_000;
        registrar(herramienta, argumentos, contexto, ejecucion, (int) duracionMs);
        return ejecucion.resultado();
    }

    private Ejecucion ejecutar(HerramientaDef herramienta, Map<String, Object> argumentos, ContextoInvocacion contexto) {
        return switch (validador.validar(herramienta, argumentos)) {
            case ResultadoValidacion.Invalido invalido ->
                    Ejecucion.rechazada(new ResultadoHerramienta.ErrorParaModelo(String.join(" ", invalido.errores())));
            case ResultadoValidacion.Valido valido -> {
                List<String> faltanIds = verificadorIds.verificar(
                        herramienta, valido.argumentos(), contexto.conversationId(), contexto.textoUsuario());
                if (!faltanIds.isEmpty()) {
                    yield Ejecucion.rechazada(new ResultadoHerramienta.ErrorParaModelo(String.join(" ", faltanIds)));
                }
                yield despachar(herramienta, completador.completar(herramienta, valido.argumentos(), contexto.userId()),
                        contexto);
            }
        };
    }

    private Ejecucion despachar(HerramientaDef herramienta, ArgumentosCanonicos argumentos, ContextoInvocacion contexto) {
        return switch (herramienta.tipo()) {
            case LECTURA, ANALITICA -> lectura(herramienta, argumentos, contexto);
            case ESCRITURA -> propuesta(herramienta, argumentos, contexto);
            case NAVEGACION, UI, CONTROL -> Ejecucion.rechazada(new ResultadoHerramienta.ErrorParaModelo(
                    "La herramienta " + herramienta.codigo() + " no es de datos y no se ejecuta aqui."));
        };
    }

    private Ejecucion lectura(HerramientaDef herramienta, ArgumentosCanonicos argumentos, ContextoInvocacion contexto) {
        RutaQuery ruta = herramienta.ruta().orElseThrow(
                () -> new IllegalStateException("herramienta de datos sin ruta: " + herramienta.codigo()));
        Peticion peticion = ConstructorPeticion.construir(ruta, argumentos);
        RespuestaQuery respuesta = queryService.invocar(
                peticion.metodo(), peticion.ruta(), peticion.query(), peticion.body(), contexto.bearer());
        return switch (respuesta) {
            case RespuestaQuery.Exito exito -> {
                List<Map<String, Object>> sinSensibles = filtro.aplicar(exito.filas());
                boolean truncado = sinSensibles.size() > maxFilas;
                List<Map<String, Object>> visibles = truncado ? sinSensibles.subList(0, maxFilas) : sinSensibles;
                // Solo cuenta como visto lo que el modelo recibe: el resto no existe para el.
                registroIds.registrar(contexto.conversationId(), visibles);
                yield new Ejecucion(new ResultadoHerramienta.Datos(visibles, truncado), EstadoInvocacion.OK, null,
                        "OK: " + visibles.size() + " filas" + (truncado ? " (cortadas)" : ""));
            }
            case RespuestaQuery.ErrorCliente error -> new Ejecucion(
                    new ResultadoHerramienta.ErrorParaModelo(traducir(error)),
                    EstadoInvocacion.ERROR, error.status(), "ERROR " + error.status());
            case RespuestaQuery.ErrorServidor _ -> new Ejecucion(
                    new ResultadoHerramienta.ErrorParaModelo(ERROR_SERVIDOR),
                    EstadoInvocacion.ERROR, null, "ERROR de servicio");
        };
    }

    private Ejecucion propuesta(HerramientaDef herramienta, ArgumentosCanonicos argumentos, ContextoInvocacion contexto) {
        ResultadoHerramienta.RequiereConfirmacion confirmacion = new ResultadoHerramienta.RequiereConfirmacion(
                argumentos, Redaccion.resumenPropuesta(herramienta, argumentos));
        try {
            contexto.alProponer().accept(confirmacion);
        } catch (RuntimeException e) {
            log.error("No se pudo registrar la accion pendiente de {}: {}",
                    herramienta.codigo(), e.getClass().getSimpleName());
            return new Ejecucion(new ResultadoHerramienta.ErrorParaModelo(
                    "No pude preparar la accion para confirmarla. Intentalo de nuevo."),
                    EstadoInvocacion.ERROR, null, "ERROR al preparar la accion");
        }
        return new Ejecucion(confirmacion, EstadoInvocacion.PENDIENTE, null, "pendiente de confirmacion");
    }

    /** Frases para el modelo por cada codigo de error del query-service. */
    public static String traducir(RespuestaQuery.ErrorCliente error) {
        String motivo = error.mensaje();
        return switch (error.status()) {
            case 400 -> "Datos no validos para el servicio academico: " + motivo;
            case 403 -> "No tienes permiso para esta accion: " + motivo;
            case 404 -> "No se encontro lo pedido: " + motivo;
            case 409 -> "Conflicto con el estado actual: " + motivo;
            default -> "El servicio academico rechazo la operacion (" + error.status() + "): " + motivo;
        };
    }

    private void registrar(HerramientaDef herramienta, Map<String, Object> argumentos,
                           ContextoInvocacion contexto, Ejecucion ejecucion, int duracionMs) {
        Set<String> nombres = NombresParametro.de(herramienta.parametros()).nombres();
        try {
            almacen.insertar(new ToolInvocacionStore.NuevaInvocacion(
                    contexto.mensajeId(),
                    herramienta.id(),
                    herramienta.codigo(),
                    Redaccion.clavesJson(argumentos, nombres),
                    ejecucion.estado(),
                    ejecucion.httpStatus(),
                    ejecucion.resumen(),
                    duracionMs));
        } catch (RuntimeException e) {
            log.warn("No se pudo registrar la invocacion de {}: {}", herramienta.codigo(), e.getClass().getSimpleName());
        }
    }

    /** Lo que se hizo, para el registro y para el resultado. */
    private record Ejecucion(ResultadoHerramienta resultado, EstadoInvocacion estado, Integer httpStatus, String resumen) {

        static Ejecucion rechazada(ResultadoHerramienta.ErrorParaModelo error) {
            return new Ejecucion(error, EstadoInvocacion.RECHAZADA, null, "argumentos rechazados");
        }
    }
}
