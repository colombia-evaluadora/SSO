package com.co.eurekatic.aicontrol.agente.ui.acciones;

import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.AccionUi;
import com.co.eurekatic.aicontrol.agente.ui.contexto.CampoUi;
import com.co.eurekatic.aicontrol.agente.ui.contexto.ContextoUi;
import com.co.eurekatic.aicontrol.agente.ui.contexto.FormularioUi;
import com.co.eurekatic.aicontrol.agente.ui.contexto.OrigenFormulario;
import com.co.eurekatic.aicontrol.agente.ui.registro.FormularioRegistrado;
import com.co.eurekatic.aicontrol.agente.ui.registro.Pantalla;
import com.co.eurekatic.aicontrol.agente.ui.registro.RegistroUi;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.regex.Pattern;

/**
 * Valida cada accion de UI contra lo que hay de verdad: pantallas que el usuario ve, formularios
 * registrados y abiertos, campos que el formulario declara, opciones de cada seleccion y, en los
 * formularios de la base, las secciones que la base oculta. Puro: todo llega resuelto en {@link Entorno}.
 *
 * <p>Lo que no pasa se descarta con un motivo legible para el modelo; un RELLENAR con algunos campos
 * invalidos conserva los validos.
 */
public final class ValidadorAccionesUi {

    static final int MAX_VALOR = 200;
    private static final Pattern CLAVE = Pattern.compile("[A-Za-z][A-Za-z0-9_.]{0,59}");
    private static final Pattern PESTANA = Pattern.compile("[\\p{L}\\p{N} _.-]{1,60}");

    private ValidadorAccionesUi() {
    }

    /**
     * @param contexto        pantalla segun el front
     * @param pantallas       pantallas que el usuario ve, por codigo
     * @param registro        formularios registrados
     * @param configuraciones configuracion de la base por codigo de formulario DB; si falta, ese
     *                        formulario no se rellena
     */
    public record Entorno(ContextoUi contexto, Map<String, Pantalla> pantallas, RegistroUi registro,
                          Map<String, ConfiguracionCamposDb> configuraciones) {
        public Entorno {
            Objects.requireNonNull(contexto, "contexto");
            Objects.requireNonNull(registro, "registro");
            pantallas = Map.copyOf(pantallas);
            configuraciones = Map.copyOf(configuraciones);
        }
    }

    public record Resultado(List<AccionUi> aceptadas, List<String> rechazos) {
        public Resultado {
            aceptadas = List.copyOf(aceptadas);
            rechazos = List.copyOf(rechazos);
        }
    }

    public static Resultado validar(List<AccionUi> propuestas, Entorno entorno) {
        List<AccionUi> aceptadas = new ArrayList<>();
        List<String> rechazos = new ArrayList<>();
        for (AccionUi propuesta : propuestas) {
            Veredicto veredicto = switch (propuesta) {
                case AccionUi.Navegar n -> navegar(n, entorno);
                case AccionUi.Rellenar r -> rellenar(r, entorno);
                case AccionUi.LimpiarCampo l -> campoDeFormulario(l.formulario(), l.campo(), entorno).map(Veredicto::rechazo)
                        .orElse(new Veredicto(Optional.of(l), List.of()));
                case AccionUi.Resaltar r -> campoDeFormulario(r.formulario(), r.campo(), entorno).map(Veredicto::rechazo)
                        .orElse(new Veredicto(Optional.of(r), List.of()));
                case AccionUi.AbrirPestana p -> PESTANA.matcher(p.pestana()).matches()
                        ? new Veredicto(Optional.of(p), List.of())
                        : Veredicto.rechazo("Nombre de pestaña no valido.");
                case AccionUi.AplicarFiltros f -> filtros(f, entorno.contexto());
            };
            veredicto.aceptada().ifPresent(aceptadas::add);
            rechazos.addAll(veredicto.motivos());
        }
        return new Resultado(aceptadas, rechazos);
    }

    private static Veredicto navegar(AccionUi.Navegar accion, Entorno entorno) {
        Pantalla pantalla = entorno.pantallas().get(accion.pantalla());
        if (pantalla == null) {
            return Veredicto.rechazo("La pantalla " + accion.pantalla() + " no existe o no la puedes ver.");
        }
        boolean paramsValidos = accion.params().entrySet().stream()
                .allMatch(e -> CLAVE.matcher(e.getKey()).matches() && e.getValue().length() <= MAX_VALOR);
        if (!paramsValidos) {
            return Veredicto.rechazo("Parametros de navegacion no validos para " + accion.pantalla() + ".");
        }
        return new Veredicto(Optional.of(new AccionUi.Navegar(pantalla.codigo(), pantalla.url(), accion.params())),
                List.of());
    }

    private static Veredicto rellenar(AccionUi.Rellenar accion, Entorno entorno) {
        Optional<String> sinFormulario = formularioUsable(accion.formulario(), entorno);
        if (sinFormulario.isPresent()) {
            return Veredicto.rechazo(sinFormulario.get());
        }
        FormularioUi abierto = entorno.contexto().formulario(accion.formulario()).orElseThrow();
        Optional<ConfiguracionCamposDb> configuracion = Optional.ofNullable(entorno.configuraciones().get(accion.formulario()));
        Map<String, Object> validos = new LinkedHashMap<>();
        List<String> motivos = new ArrayList<>();
        accion.valores().forEach((campo, valor) -> motivoCampo(abierto, campo, configuracion)
                .or(() -> admite(abierto.campo(campo).orElseThrow(), valor))
                .ifPresentOrElse(motivos::add, () -> validos.put(campo, valor)));
        if (validos.isEmpty()) {
            motivos.add("Ningun valor del formulario " + accion.formulario() + " se pudo aplicar.");
            return new Veredicto(Optional.empty(), motivos);
        }
        return new Veredicto(Optional.of(new AccionUi.Rellenar(accion.formulario(), validos)), motivos);
    }

    /** Motivo por el que un campo de un formulario usable no se puede tocar; vacio si se puede. */
    private static Optional<String> campoDeFormulario(String formulario, String campo, Entorno entorno) {
        return formularioUsable(formulario, entorno).or(() -> motivoCampo(
                entorno.contexto().formulario(formulario).orElseThrow(), campo,
                Optional.ofNullable(entorno.configuraciones().get(formulario))));
    }

    /** Registrado, abierto y, si es de la base, con su configuracion obtenida. */
    private static Optional<String> formularioUsable(String codigo, Entorno entorno) {
        Optional<FormularioRegistrado> registrado = entorno.registro().formulario(codigo);
        if (registrado.isEmpty()) {
            return Optional.of("El formulario " + codigo + " no se puede rellenar desde el asistente.");
        }
        if (entorno.contexto().formulario(codigo).isEmpty()) {
            return Optional.of("El formulario " + codigo + " no esta abierto: lleva antes a la persona a su pantalla.");
        }
        if (registrado.get().origen() == OrigenFormulario.DB && !entorno.configuraciones().containsKey(codigo)) {
            return Optional.of("No se pudo comprobar la configuracion del formulario " + codigo + ".");
        }
        return Optional.empty();
    }

    private static Optional<String> motivoCampo(FormularioUi abierto, String campo,
                                                Optional<ConfiguracionCamposDb> configuracion) {
        if (abierto.campo(campo).isEmpty()) {
            return Optional.of("El campo " + campo + " no existe en el formulario " + abierto.codigo() + ".");
        }
        if (configuracion.filter(c -> c.oculta(campo)).isPresent()) {
            return Optional.of("El campo " + campo + " no aplica en este registro.");
        }
        return Optional.empty();
    }

    private static Optional<String> admite(CampoUi campo, Object valor) {
        if (String.valueOf(valor).length() > MAX_VALOR || !campo.admite(valor)) {
            return Optional.of("Valor no valido para " + campo.etiqueta() + ".");
        }
        return Optional.empty();
    }

    private static Veredicto filtros(AccionUi.AplicarFiltros accion, ContextoUi contexto) {
        if (accion.filtros().isEmpty()) {
            return Veredicto.rechazo("Indica al menos un filtro.");
        }
        Map<String, Object> validos = new LinkedHashMap<>();
        List<String> motivos = new ArrayList<>();
        accion.filtros().forEach((nombre, valor) -> {
            if (contexto.filtros().contains(nombre) && String.valueOf(valor).length() <= MAX_VALOR) {
                validos.put(nombre, valor);
            } else {
                motivos.add("El filtro " + nombre + " no existe en esta pantalla.");
            }
        });
        return validos.isEmpty()
                ? new Veredicto(Optional.empty(), motivos)
                : new Veredicto(Optional.of(new AccionUi.AplicarFiltros(validos)), motivos);
    }

    /** Resultado de una accion: la accion (quiza recortada) si se acepta, y los motivos de lo descartado. */
    private record Veredicto(Optional<AccionUi> aceptada, List<String> motivos) {

        static Veredicto rechazo(String motivo) {
            return new Veredicto(Optional.empty(), List.of(motivo));
        }
    }
}
