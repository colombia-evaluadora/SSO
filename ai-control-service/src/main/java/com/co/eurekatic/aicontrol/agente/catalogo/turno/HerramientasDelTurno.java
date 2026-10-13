package com.co.eurekatic.aicontrol.agente.catalogo.turno;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.CatalogoHerramientas;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.seguridad.Riesgo;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Minimo privilegio por turno: que herramientas ve el modelo en esta peticion. Pura respecto de
 * sus datos (menus, roles y riesgo llegan ya resueltos).
 *
 * <p>Una herramienta pasa si cumple las cuatro condiciones:
 * <ol>
 *   <li>su tipo esta entre los permitidos por la intencion;</li>
 *   <li>su menu lo tiene el usuario. Sin menu, una LECTURA o una de CONTROL pasan (el gate de su
 *       ruta decide); una ESCRITURA o una ANALITICA sin menu se excluyen;</li>
 *   <li>el rol del JWT figura en su {@code role_query}; sin roles declarados no se filtra por rol;</li>
 *   <li>las escrituras solo si el menu no es de solo lectura y el riesgo del turno es BAJO.</li>
 * </ol>
 */
@Component
public class HerramientasDelTurno {

    /** Tipos que pueden no tener menu: la LECTURA lo filtra su rol y su ruta; la CONTROL no toca datos. */
    private static final Set<TipoHerramienta> SIN_MENU_PERMITIDA = Set.of(TipoHerramienta.LECTURA, TipoHerramienta.CONTROL);

    /**
     * @param catalogo         catalogo vigente
     * @param rolesUsuario     roles del JWT del usuario
     * @param menus            menus del usuario por codigo, de {@link MenusUsuario}
     * @param riesgo           riesgo final del mensaje del turno
     * @param tiposPermitidos  tipos que la intencion admite en este turno
     * @return herramientas en el orden del catalogo
     */
    public List<HerramientaDef> calcular(CatalogoHerramientas catalogo, Set<String> rolesUsuario,
                                                   Map<String, AccesoMenu> menus, Riesgo riesgo,
                                                   Set<TipoHerramienta> tiposPermitidos) {
        return catalogo.todas().stream()
                .filter(h -> tiposPermitidos.contains(h.tipo()))
                .filter(h -> menuPermitido(h, menus))
                .filter(h -> rolPermitido(h, rolesUsuario))
                .filter(h -> escrituraPermitida(h, menus, riesgo))
                .toList();
    }

    private static boolean menuPermitido(HerramientaDef herramienta, Map<String, AccesoMenu> menus) {
        return herramienta.menuCodigo()
                .map(menus::containsKey)
                .orElseGet(() -> SIN_MENU_PERMITIDA.contains(herramienta.tipo()));
    }

    private static boolean rolPermitido(HerramientaDef herramienta, Set<String> rolesUsuario) {
        return herramienta.roles().isEmpty() || herramienta.roles().stream().anyMatch(rolesUsuario::contains);
    }

    private static boolean escrituraPermitida(HerramientaDef herramienta, Map<String, AccesoMenu> menus, Riesgo riesgo) {
        if (!herramienta.tipo().escribe()) {
            return true;
        }
        boolean soloLectura = herramienta.menuCodigo()
                .map(menus::get)
                .map(AccesoMenu::soloLectura)
                .orElse(true);
        return !soloLectura && riesgo.permiteEscritura();
    }
}
