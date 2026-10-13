package com.co.eurekatic.aicontrol.agente.catalogo.carga;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.Restriccion;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class TechoHerramientasTest {

    private final TechoHerramientas techo = new TechoHerramientas();

    @Test
    void rutasDelCatalogoRealPasanElTecho() {
        // Rutas de V557.2 que el catalogo real ya usa: ninguna debe caer en el techo.
        for (String ruta : List.of("/planeador/actividades/:ID/calificar-bulk/escala",
                "/establecimientos/funcionarios/query", "/planeador/unidades/:ID/criterios",
                "/periodos-academicos/query", "/my-menus", "/select/:CATEGORIA")) {
            assertThat(techo.motivoRechazo(herramienta(TipoHerramienta.LECTURA, ruta, HttpMethod.GET, true)))
                    .as(ruta).isEmpty();
        }
    }

    @Test
    void rutasDeBorradoPermisosRolesPigseAuditoriaYPortabilidadSeRechazan() {
        for (String ruta : List.of("/planeador/actividades/:ID/eliminar", "/usuarios/:ID/baja",
                "/usuarios/:ID/permisos", "/x/filtros-permiso", "/roles/:ID/menus", "/pigse/documentos",
                "/auditoria/registro", "/cargas/import", "/reportes/export", "/x/register")) {
            assertThat(techo.motivoRechazo(herramienta(TipoHerramienta.LECTURA, ruta, HttpMethod.GET, true)))
                    .as(ruta).isPresent();
        }
    }

    @Test
    void metodoDeleteSeRechazaAunqueLaRutaSeaInocua() {
        assertThat(techo.motivoRechazo(herramienta(TipoHerramienta.ESCRITURA, "/planeador/actividades/:ID",
                HttpMethod.DELETE, true))).isPresent();
    }

    @Test
    void unaLecturaSoloVaPorGetOPorPostDeListado() {
        assertThat(techo.motivoRechazo(herramienta(TipoHerramienta.LECTURA, "/establecimientos/funcionarios/query",
                HttpMethod.POST, false))).isEmpty();
        assertThat(techo.motivoRechazo(herramienta(TipoHerramienta.LECTURA, "/sedes/jornadas-activas",
                HttpMethod.POST, false))).isEmpty();
        assertThat(techo.motivoRechazo(herramienta(TipoHerramienta.LECTURA, "/planeador/actividades",
                HttpMethod.POST, false))).as("POST que crea").isPresent();
        assertThat(techo.motivoRechazo(herramienta(TipoHerramienta.ANALITICA, "/planeador/actividades/:ID",
                HttpMethod.PATCH, false))).as("PATCH disfrazado de analitica").isPresent();
        assertThat(techo.motivoRechazo(herramienta(TipoHerramienta.LECTURA, "/planeador/unidades/:ID",
                HttpMethod.PUT, false))).isPresent();
    }

    @Test
    void unaEscrituraNoPuedeIrPorGet() {
        assertThat(techo.motivoRechazo(herramienta(TipoHerramienta.ESCRITURA, "/planeador/actividades",
                HttpMethod.GET, true))).isPresent();
    }

    @Test
    void escrituraSinConfirmacionSeRechaza() {
        assertThat(techo.motivoRechazo(herramienta(TipoHerramienta.ESCRITURA, "/planeador/actividades",
                HttpMethod.POST, false))).isPresent();
    }

    @Test
    void herramientaDeControlSinRutaPasa() {
        HerramientaDef control = new HerramientaDef(401L, "buscar_pantalla", TipoHerramienta.CONTROL, "d", List.of(),
                false, List.of(), 1, Optional.empty(), Optional.empty(), Set.of());
        assertThat(techo.motivoRechazo(control)).isEmpty();
    }

    private static HerramientaDef herramienta(TipoHerramienta tipo, String ruta, HttpMethod metodo, boolean confirma) {
        return new HerramientaDef(402L, "h_prueba", tipo, "d", List.of(), confirma, List.of(), 1,
                Optional.of("MENU"), Optional.of(new RutaQuery(metodo, ruta, Map.of(), Map.<String, Restriccion>of())),
                Set.of());
    }
}
