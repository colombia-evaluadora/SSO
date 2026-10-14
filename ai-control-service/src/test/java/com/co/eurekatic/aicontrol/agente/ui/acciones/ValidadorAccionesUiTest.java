package com.co.eurekatic.aicontrol.agente.ui.acciones;

import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.AccionUi;
import com.co.eurekatic.aicontrol.agente.ui.UiFixture;
import com.co.eurekatic.aicontrol.agente.ui.contexto.ContextoUi;
import com.co.eurekatic.aicontrol.agente.ui.registro.Pantalla;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;

class ValidadorAccionesUiTest {

    private static final Map<String, Pantalla> VISIBLES = UiFixture.REGISTRO.pantallasVisibles(UiFixture.MENUS_DOCENTE)
            .stream().collect(Collectors.toMap(Pantalla::codigo, Function.identity()));

    @Test
    void navegarTomaLaUrlDelRegistroYNoLaDelModelo() {
        ValidadorAccionesUi.Resultado r = validar(List.of(new AccionUi.Navegar("planeador", "https://otro.sitio", Map.of())),
                Map.of());

        assertThat(r.aceptadas()).containsExactly(
                new AccionUi.Navegar("planeador", "/app/planeador/actividades", Map.of()));
        assertThat(r.rechazos()).isEmpty();
    }

    @Test
    void noSePuedeNavegarAUnaPantallaSinAcceso() {
        ValidadorAccionesUi.Resultado r = validar(List.of(new AccionUi.Navegar("config_roles_menus", "", Map.of())),
                Map.of());

        assertThat(r.aceptadas()).isEmpty();
        assertThat(r.rechazos()).singleElement().asString().contains("no la puedes ver");
    }

    @Test
    void rellenarConservaLosCamposValidosYDescartaLosDemas() {
        ValidadorAccionesUi.Resultado r = validar(List.of(new AccionUi.Rellenar("funcionario.crear", Map.of(
                "nombres", "Ana",
                "cargo", "SUPERUSUARIO",
                "inventado", "x",
                "fechaIngreso", "2026-02-01"))), Map.of());

        assertThat(r.aceptadas()).singleElement().isInstanceOfSatisfying(AccionUi.Rellenar.class,
                a -> assertThat(a.valores()).containsOnlyKeys("nombres", "fechaIngreso"));
        assertThat(r.rechazos()).hasSize(2)
                .anySatisfy(m -> assertThat(m).contains("Cargo"))
                .anySatisfy(m -> assertThat(m).contains("inventado"));
    }

    @Test
    void unCampoDeRolesOPermisosNoSeRellenaNiSeLimpiaPeroSiSeResalta() {
        ValidadorAccionesUi.Resultado r = validar(List.of(
                new AccionUi.Rellenar("funcionario.crear", Map.of("nombres", "Ana", "perfil", "COORDINADOR")),
                new AccionUi.LimpiarCampo("funcionario.crear", "perfil"),
                new AccionUi.Resaltar("funcionario.crear", "perfil")), Map.of());

        assertThat(r.aceptadas()).hasSize(2)
                .anySatisfy(a -> assertThat(a).isInstanceOfSatisfying(AccionUi.Rellenar.class,
                        rellenar -> assertThat(rellenar.valores()).containsOnlyKeys("nombres")))
                .anySatisfy(a -> assertThat(a).isInstanceOf(AccionUi.Resaltar.class));
        assertThat(r.rechazos()).hasSize(2).allSatisfy(m -> assertThat(m).contains("roles, permisos"));
    }

    @Test
    void unFormularioNoRegistradoONoAbiertoNoSeToca() {
        ValidadorAccionesUi.Resultado noRegistrado = validar(
                List.of(new AccionUi.Rellenar("matricula.solicitud", Map.of("x", "1"))), Map.of());
        ValidadorAccionesUi.Resultado noAbierto = ValidadorAccionesUi.validar(
                List.of(new AccionUi.Resaltar("funcionario.crear", "nombres")),
                new ValidadorAccionesUi.Entorno(ContextoUi.vacio(),
                        VISIBLES, UiFixture.REGISTRO, Map.of()));

        assertThat(noRegistrado.aceptadas()).isEmpty();
        assertThat(noAbierto.aceptadas()).isEmpty();
        assertThat(noAbierto.rechazos()).singleElement().asString().contains("no esta abierto");
    }

    @Test
    void unFormularioDeLaBaseSinConfiguracionNoSeRellena() {
        ValidadorAccionesUi.Resultado r = validar(
                List.of(new AccionUi.Rellenar("planeador.actividad", Map.of("titulo", "Fracciones"))), Map.of());

        assertThat(r.aceptadas()).isEmpty();
        assertThat(r.rechazos()).singleElement().asString().contains("configuracion");
    }

    @Test
    void enUnFormularioDeLaBaseLasSeccionesOcultasNoSeTocan() {
        ConfiguracionCamposDb config = ConfiguracionCamposDb.desde(List.of(Map.of(
                "recuperacion", Map.of("visible", false, "requerido", false))));

        ValidadorAccionesUi.Resultado r = validar(List.of(new AccionUi.Rellenar("planeador.actividad", Map.of(
                "titulo", "Fracciones", "recuperacionFecha", "2026-11-01"))), Map.of("planeador.actividad", config));

        assertThat(r.aceptadas()).singleElement().isInstanceOfSatisfying(AccionUi.Rellenar.class,
                a -> assertThat(a.valores()).containsOnlyKeys("titulo"));
        assertThat(r.rechazos()).singleElement().asString().contains("no aplica");
    }

    @Test
    void soloSeAplicanFiltrosQueLaPantallaDeclara() {
        ValidadorAccionesUi.Resultado r = validar(List.of(new AccionUi.AplicarFiltros(Map.of("sede", "1", "rol", "x"))),
                Map.of());

        assertThat(r.aceptadas()).containsExactly(new AccionUi.AplicarFiltros(Map.of("sede", "1")));
        assertThat(r.rechazos()).singleElement().asString().contains("rol");
    }

    @Test
    void unaPestanaConCaracteresRarosSeRechaza() {
        ValidadorAccionesUi.Resultado r = validar(List.of(
                new AccionUi.AbrirPestana("Evaluación"), new AccionUi.AbrirPestana("<script>")), Map.of());

        assertThat(r.aceptadas()).containsExactly(new AccionUi.AbrirPestana("Evaluación"));
        assertThat(r.rechazos()).hasSize(1);
    }

    private static ValidadorAccionesUi.Resultado validar(List<AccionUi> acciones,
                                                        Map<String, ConfiguracionCamposDb> configuraciones) {
        return ValidadorAccionesUi.validar(acciones,
                new ValidadorAccionesUi.Entorno(UiFixture.CONTEXTO, VISIBLES, UiFixture.REGISTRO, configuraciones));
    }
}
