package com.co.eurekatic.aicontrol.agente.nucleo;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ObservadorResultados;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ResultadoHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ResultadoHerramienta.RequiereConfirmacion;
import com.co.eurekatic.aicontrol.agente.catalogo.turno.AccesoMenu;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.seguridad.seudonimos.TablaSeudonimos;
import com.co.eurekatic.aicontrol.agente.ui.contexto.ContextoUi;
import org.springframework.ai.chat.model.ToolContext;

import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Estado de un turno que las herramientas necesitan leer o escribir: las herramientas de datos que
 * el modelo ve, la pantalla y los menus del usuario, la respuesta directa que una herramienta de
 * control ha dejado, las escrituras propuestas y la ultima tabla de analitica. Vive lo que dura el
 * turno y viaja en el {@code ToolContext}; nunca se comparte entre turnos.
 */
public final class TurnoContexto implements ObservadorResultados {

    /** Clave bajo la que el turno viaja en el {@code ToolContext}. */
    public static final String CLAVE = "turnoContexto";

    private final List<HerramientaDef> herramientas;
    private final ContextoUi contextoUi;
    private final Map<String, AccesoMenu> menus;
    private final List<RespuestaAgente> directas = new CopyOnWriteArrayList<>();
    private final List<RequiereConfirmacion> propuestas = new CopyOnWriteArrayList<>();
    private final AtomicReference<TablaAnalitica> analitica = new AtomicReference<>();
    private final TablaSeudonimos seudonimos;
    private final AtomicInteger lecturas = new AtomicInteger();
    private final AtomicBoolean preguntaDevuelta = new AtomicBoolean();

    public TurnoContexto(List<HerramientaDef> herramientas, ContextoUi contextoUi, Map<String, AccesoMenu> menus,
                         TablaSeudonimos seudonimos) {
        this.herramientas = List.copyOf(herramientas);
        this.contextoUi = Objects.requireNonNull(contextoUi, "contextoUi");
        this.menus = Map.copyOf(menus);
        this.seudonimos = Objects.requireNonNull(seudonimos, "seudonimos");
    }

    /** Turno sin pantalla, menus ni seudonimos previos: lo usan las herramientas que no dependen de la UI. */
    public TurnoContexto(List<HerramientaDef> herramientas) {
        this(herramientas, ContextoUi.vacio(), Map.of(), TablaSeudonimos.vacia());
    }

    /** Alias de los nombres de persona de la conversacion; viaja al {@code ToolContext} del turno. */
    public TablaSeudonimos seudonimos() {
        return seudonimos;
    }

    /** Lo que el front dice de la pantalla; dato no confiable. */
    public ContextoUi contextoUi() {
        return contextoUi;
    }

    /** Menus que el usuario ve, por codigo. */
    public Map<String, AccesoMenu> menus() {
        return menus;
    }

    /** Guarda la ultima tabla de una herramienta de analitica, para presentarla al cerrar el turno. */
    @Override
    public void alObtener(HerramientaDef herramienta, ResultadoHerramienta resultado) {
        if (resultado instanceof ResultadoHerramienta.Datos) {
            lecturas.incrementAndGet();
        }
        if (herramienta.tipo() == TipoHerramienta.ANALITICA && resultado instanceof ResultadoHerramienta.Datos datos) {
            analitica.set(new TablaAnalitica(herramienta.codigo(), datos.filas(), datos.truncado()));
        }
    }

    /** Consultas que devolvieron datos en este turno. */
    public int lecturas() {
        return lecturas.get();
    }

    /** Cierto solo la primera vez: una pregunta sin consultar antes se devuelve al modelo una sola vez por turno. */
    public boolean devolverPreguntaUnaVez() {
        return preguntaDevuelta.compareAndSet(false, true);
    }

    public Optional<TablaAnalitica> analitica() {
        return Optional.ofNullable(analitica.get());
    }

    /** Filas de la ultima herramienta de analitica del turno, ya filtradas de datos sensibles. */
    public record TablaAnalitica(String herramienta, List<Map<String, Object>> filas, boolean truncado) {
        public TablaAnalitica {
            Objects.requireNonNull(herramienta, "herramienta");
            filas = List.copyOf(filas);
        }
    }

    /** Recupera el turno del {@code ToolContext}. Lanza si falta: es un fallo de cableado. */
    public static TurnoContexto de(ToolContext contexto) {
        if (contexto != null && contexto.getContext().get(CLAVE) instanceof TurnoContexto turno) {
            return turno;
        }
        throw new IllegalStateException("falta el TurnoContexto en el ToolContext de la llamada");
    }

    /** Herramientas de datos que el modelo ve en este turno. */
    public List<HerramientaDef> herramientas() {
        return herramientas;
    }

    public Optional<HerramientaDef> herramienta(String codigo) {
        return herramientas.stream().filter(h -> h.codigo().equals(codigo)).findFirst();
    }

    /** Lo llama una herramienta de control que responde al usuario sin pasar por el modelo. */
    public void responderDirecto(RespuestaAgente respuesta) {
        directas.add(Objects.requireNonNull(respuesta, "respuesta"));
    }

    /** Primera respuesta directa dejada en el turno, si la hay. */
    public Optional<RespuestaAgente> directa() {
        return directas.isEmpty() ? Optional.empty() : Optional.of(directas.get(0));
    }

    /** Lo llama el invocador de herramientas por cada escritura validada que espera confirmacion. */
    public void registrarPropuesta(RequiereConfirmacion propuesta) {
        propuestas.add(Objects.requireNonNull(propuesta, "propuesta"));
    }

    public List<RequiereConfirmacion> propuestas() {
        return List.copyOf(propuestas);
    }
}
