package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoParametro;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

/** La regla de ids con tipo: un id visto como otra entidad no vale (en la bateria, el pk de un grado como grupo). */
class VerificadorIdsTipadoTest {

    private static final String CONV = "conv-1";
    private static final HerramientaDef CREAR = new HerramientaDef(1L, "crear_actividad_planeador",
            TipoHerramienta.ESCRITURA, "Crea", List.of(new ParametroDef("BODY.FK_TGRUPO", TipoParametro.texto(), "Grupo",
                    Optional.of("docentes_grupos_listar"), true, false)),
            true, List.of(), 1, Optional.empty(), Optional.empty(), Set.of());

    private final RegistroIdsEnMemoria registro = new RegistroIdsEnMemoria();
    private final VerificadorIds verificador = new VerificadorIds(registro);

    private List<String> verificar(long grupo) {
        return verificador.verificar(CREAR, new ArgumentosCanonicos(Map.of("BODY.FK_TGRUPO", grupo)), CONV, "crea la actividad");
    }

    @Test
    void elPkDeUnGradoNoValeComoGrupoCuandoYaSeVieronGrupos() {
        registro.registrar(CONV, List.of(Map.of("grupo_id", 990201, "grado_id", 990501)));

        assertThat(verificar(990501)).singleElement().asString().contains("no es un id de grupo")
                .contains("docentes_grupos_listar");
        assertThat(verificar(990201)).isEmpty();
    }

    @Test
    void unIdQueNoSalioComoOtraEntidadValeAunqueYaSeVieranGrupos() {
        // El grupo nuevo llega en una columna que no dice su entidad (p. ej. el resultado de una escritura).
        registro.registrar(CONV, List.of(Map.of("grupo_id", 990201), Map.of("id", 990333)));

        assertThat(verificar(990333)).isEmpty();
    }

    @Test
    void elPkDeUnaUnidadRecienCreadaQuedaComoIdDeUnidad() {
        registro.registrar(CONV, List.of(Map.of("fn_unidad_crear", 151)));

        assertThat(registro.consultarDe(CONV, "unidad", "151")).isEqualTo(RegistroIds.Presencia.VISTO);
    }

    @Test
    void sinNingunGrupoVistoValeLaPresenciaSinTipo() {
        registro.registrar(CONV, List.of(Map.of("id", 990201)));

        assertThat(verificar(990201)).isEmpty();
        assertThat(verificar(5)).hasSize(1);
    }
}
