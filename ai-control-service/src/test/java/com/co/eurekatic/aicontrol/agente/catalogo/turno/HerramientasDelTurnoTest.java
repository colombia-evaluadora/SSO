package com.co.eurekatic.aicontrol.agente.catalogo.turno;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.CatalogoHerramientas;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.seguridad.Riesgo;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class HerramientasDelTurnoTest {

    private static final Set<TipoHerramienta> TODOS = Set.of(TipoHerramienta.values());

    private final HerramientasDelTurno calculo = new HerramientasDelTurno();
    private CatalogoHerramientas catalogo;

    @BeforeEach
    void preparar() {
        catalogo = CatalogoHerramientas.con(List.of(
                herramienta("funcionarios_listar", TipoHerramienta.LECTURA, Optional.of("FUNCIONARIOS"),
                        Set.of("ADMIN", "CEVAL-SUPER_ADMINISTRADOR")),
                herramienta("editar_funcionario", TipoHerramienta.ESCRITURA, Optional.of("FUNCIONARIOS"),
                        Set.of("ADMIN")),
                herramienta("planeador_estadisticas", TipoHerramienta.ANALITICA, Optional.of("PLANEADOR"), Set.of()),
                herramienta("buscar_pantalla", TipoHerramienta.CONTROL, Optional.empty(), Set.of()),
                herramienta("mis_menus", TipoHerramienta.LECTURA, Optional.empty(), Set.of())));
    }

    private static HerramientaDef herramienta(String codigo, TipoHerramienta tipo, Optional<String> menu, Set<String> roles) {
        Optional<RutaQuery> ruta = tipo == TipoHerramienta.CONTROL
                ? Optional.empty()
                : Optional.of(new RutaQuery(HttpMethod.GET, "/x/" + codigo, Map.of(), Map.of()));
        return new HerramientaDef(codigo, tipo, "d", List.of(), tipo == TipoHerramienta.ESCRITURA, List.of(), 1,
                menu, ruta, roles);
    }

    private static Map<String, AccesoMenu> menus(boolean soloLectura) {
        return Map.of("FUNCIONARIOS", new AccesoMenu(soloLectura), "PLANEADOR", new AccesoMenu(false));
    }

    private List<String> codigos(List<HerramientaDef> lista) {
        return lista.stream().map(HerramientaDef::codigo).toList();
    }

    @Test
    void conAccesoDeEscrituraYRiesgoBajoVenTodoLoQueCorresponde() {
        List<String> r = codigos(calculo.calcular(catalogo, Set.of("ADMIN"), menus(false), Riesgo.BAJO, TODOS));

        assertThat(r).containsExactly("buscar_pantalla", "editar_funcionario", "funcionarios_listar",
                "planeador_estadisticas");
    }

    @Test
    void unMenuSoloLecturaQuitaLasEscrituras() {
        List<String> r = codigos(calculo.calcular(catalogo, Set.of("ADMIN"), menus(true), Riesgo.BAJO, TODOS));

        assertThat(r).doesNotContain("editar_funcionario").contains("funcionarios_listar");
    }

    @Test
    void unRiesgoMedioQuitaLasEscriturasPeroNoLasLecturas() {
        List<String> r = codigos(calculo.calcular(catalogo, Set.of("ADMIN"), menus(false), Riesgo.MEDIO, TODOS));

        assertThat(r).doesNotContain("editar_funcionario").contains("funcionarios_listar", "buscar_pantalla");
    }

    @Test
    void sinRolDelJwtNoSeVeLaHerramientaDeEsaRuta() {
        List<String> r = codigos(calculo.calcular(catalogo, Set.of("USER"), menus(false), Riesgo.BAJO, TODOS));

        assertThat(r).doesNotContain("funcionarios_listar", "editar_funcionario").contains("planeador_estadisticas");
    }

    @Test
    void unaHerramientaSinRolesDeclaradosNoFiltraPorRol() {
        List<String> r = codigos(calculo.calcular(catalogo, Set.of(), menus(false), Riesgo.BAJO, TODOS));

        assertThat(r).contains("planeador_estadisticas");
    }

    @Test
    void laIntencionRecortaPorTipo() {
        List<String> r = codigos(calculo.calcular(catalogo, Set.of("ADMIN"), menus(false), Riesgo.BAJO,
                Set.of(TipoHerramienta.LECTURA)));

        assertThat(r).containsExactly("funcionarios_listar");
    }

    @Test
    void sinMenusSoloQuedanLasDeControlYUnaSinMenuNoEsDeDatos() {
        List<String> r = codigos(calculo.calcular(catalogo, Set.of("ADMIN"), Map.of(), Riesgo.BAJO, TODOS));

        assertThat(r).containsExactly("buscar_pantalla");
    }
}
