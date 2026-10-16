package com.co.eurekatic.aicontrol.agente.ui.sugerencias;

import com.co.eurekatic.aicontrol.agente.catalogo.carga.CatalogoHerramientasLoader;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.turno.AccesoMenu;
import com.co.eurekatic.aicontrol.agente.catalogo.turno.HerramientasDelTurno;
import com.co.eurekatic.aicontrol.agente.catalogo.turno.MenusUsuario;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.seguridad.Riesgo;
import com.co.eurekatic.aicontrol.agente.ui.registro.Pantalla;
import com.co.eurekatic.aicontrol.agente.ui.registro.RegistroUi;
import com.co.eurekatic.aicontrol.agente.ui.registro.RegistroUiLoader;
import com.co.eurekatic.aicontrol.agente.ui.sugerencias.CatalogoSugerencias.Sugerencia;
import org.springframework.stereotype.Service;

import java.util.Comparator;
import java.util.EnumSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/**
 * Sugerencias de mensajes para la pantalla abierta y resumen de lo que el asistente puede hacer por el
 * usuario. Usa el mismo filtro que un turno (menus, roles y solo lectura), asi que nunca sugiere algo que
 * el asistente le negaria. Es una ayuda de UX: no autoriza nada.
 */
@Service
public class SugerenciasService {

    static final int MAX_SUGERENCIAS = 6;
    private static final Set<TipoHerramienta> TODOS_LOS_TIPOS = EnumSet.allOf(TipoHerramienta.class);

    private final MenusUsuario menus;
    private final CatalogoHerramientasLoader catalogo;
    private final HerramientasDelTurno filtro;
    private final RegistroUiLoader registro;

    public SugerenciasService(MenusUsuario menus, CatalogoHerramientasLoader catalogo, HerramientasDelTurno filtro,
                              RegistroUiLoader registro) {
        this.menus = menus;
        this.catalogo = catalogo;
        this.filtro = filtro;
        this.registro = registro;
    }

    public Resultado para(UsuarioAgente usuario, String ruta) {
        Map<String, AccesoMenu> menusUsuario = menus.de(usuario.userId());
        List<HerramientaDef> herramientas = filtro.calcular(catalogo.catalogo(), usuario.roles(), menusUsuario,
                Riesgo.BAJO, TODOS_LOS_TIPOS);
        RegistroUi ui = registro.registro();
        List<Pantalla> visibles = ui.pantallasVisibles(menusUsuario);
        Optional<Pantalla> pantalla = pantallaDe(ruta, visibles);
        Capacidades capacidades = capacidades(herramientas, visibles, ui, menusUsuario);
        return new Resultado(pantalla, sugerencias(pantalla, herramientas, capacidades), capacidades);
    }

    /** La pantalla cuya URL es el prefijo mas largo de la ruta (sin query ni fragmento). */
    static Optional<Pantalla> pantallaDe(String ruta, List<Pantalla> visibles) {
        if (ruta == null || ruta.isBlank()) {
            return Optional.empty();
        }
        String camino = ruta.strip().split("[?#]", 2)[0];
        return visibles.stream()
                .filter(p -> !p.url().isBlank() && (camino.equals(p.url()) || camino.startsWith(barra(p.url()))))
                .max(Comparator.comparingInt(p -> p.url().length()));
    }

    private static String barra(String url) {
        return url.endsWith("/") ? url : url + "/";
    }

    /** Primero las del menu de la pantalla; despues las generales, hasta {@value #MAX_SUGERENCIAS}. */
    static List<Sugerencia> sugerencias(Optional<Pantalla> pantalla, List<HerramientaDef> herramientas,
                                        Capacidades capacidades) {
        Optional<String> menu = pantalla.map(Pantalla::menuCodigo);
        Stream<Sugerencia> delMenu = menu.stream().flatMap(m -> CatalogoSugerencias.todas().stream()
                .filter(s -> s.menuCodigo().equals(Optional.of(m))));
        Stream<Sugerencia> generales = CatalogoSugerencias.todas().stream().filter(s -> s.menuCodigo().isEmpty());
        return Stream.concat(delMenu, generales)
                .filter(s -> cumplible(s, herramientas, capacidades))
                .limit(MAX_SUGERENCIAS)
                .toList();
    }

    private static boolean cumplible(Sugerencia s, List<HerramientaDef> herramientas, Capacidades capacidades) {
        return switch (s.tipo()) {
            case AYUDA -> true;
            case NAVEGACION -> capacidades.navegar();
            case CONSULTA -> herramientas.stream().anyMatch(h -> (h.tipo() == TipoHerramienta.LECTURA || h.tipo() == TipoHerramienta.ANALITICA)
                    && h.menuCodigo().equals(s.menuCodigo()));
            case ACCION -> herramientas.stream().anyMatch(h -> h.tipo().escribe()
                    && h.menuCodigo().equals(s.menuCodigo()));
        };
    }

    static Capacidades capacidades(List<HerramientaDef> herramientas, List<Pantalla> visibles, RegistroUi ui,
                                   Map<String, AccesoMenu> menusUsuario) {
        Set<String> menusConHerramientas = herramientas.stream()
                .map(HerramientaDef::menuCodigo)
                .flatMap(Optional::stream)
                .collect(Collectors.toSet());
        List<String> modulos = visibles.stream()
                .filter(p -> menusConHerramientas.contains(p.menuCodigo()))
                .map(Pantalla::nombre)
                .distinct()
                .sorted()
                .toList();
        return new Capacidades(
                herramientas.stream().anyMatch(h -> h.tipo() == TipoHerramienta.LECTURA),
                herramientas.stream().anyMatch(h -> h.tipo().escribe()),
                herramientas.stream().anyMatch(h -> h.tipo() == TipoHerramienta.ANALITICA),
                !visibles.isEmpty(),
                !ui.formulariosVisibles(menusUsuario).isEmpty(),
                modulos);
    }

    /**
     * @param consultar          puede leer datos (listados, detalles)
     * @param proponerAcciones   puede preparar escrituras para confirmar con boton
     * @param estadisticas       puede pedir consultas analiticas
     * @param navegar            puede llevar a pantallas
     * @param rellenarFormularios hay formularios registrados que puede rellenar
     * @param modulos            nombres de las pantallas donde tiene herramientas de datos
     */
    public record Capacidades(boolean consultar, boolean proponerAcciones, boolean estadisticas, boolean navegar,
                              boolean rellenarFormularios, List<String> modulos) {

        public Capacidades {
            modulos = List.copyOf(modulos);
        }
    }

    public record Resultado(Optional<Pantalla> pantalla, List<Sugerencia> sugerencias, Capacidades capacidades) {

        public Resultado {
            sugerencias = List.copyOf(sugerencias);
        }
    }
}
