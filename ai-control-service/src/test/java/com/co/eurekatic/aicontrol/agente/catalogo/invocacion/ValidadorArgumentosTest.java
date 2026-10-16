package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.CatalogoFixture;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class ValidadorArgumentosTest {

    private final ValidadorArgumentos validador = new ValidadorArgumentos();
    private final HerramientaDef editar = CatalogoFixture.editarFuncionarioDef();

    @Test
    void argumentosValidosQuedanConClavesCanonicasYAnidadoBody() {
        ResultadoValidacion r = validador.validar(editar, Map.of("id", 12, "person_email", "a@b.co"));

        ArgumentosCanonicos args = ((ResultadoValidacion.Valido) r).argumentos();
        assertThat(args.pathParams()).containsExactly(Map.entry("ID", 12));
        assertThat(args.body()).isEqualTo(Map.of("PERSON", Map.of("EMAIL", "a@b.co")));
    }

    @Test
    void faltaUnPathParamObligatorioYSeIndicaDeDondeSale() {
        ResultadoValidacion r = validador.validar(editar, Map.of("person_email", "a@b.co"));

        assertThat(r).isInstanceOf(ResultadoValidacion.Invalido.class);
        assertThat(((ResultadoValidacion.Invalido) r).errores())
                .anySatisfy(e -> assertThat(e).contains("Falta 'id'").contains("funcionarios_listar"));
    }

    @Test
    void clavesFueraDeLaAllowlistSeDescartanSinError() {
        // status y fkarchivofoto estan en param_types de la base pero no en la allowlist.
        ResultadoValidacion r = validador.validar(editar,
                Map.of("id", 12, "status", "A", "fkarchivofoto", 99, "person_email", "a@b.co"));

        ArgumentosCanonicos args = ((ResultadoValidacion.Valido) r).argumentos();
        assertThat(args.planos()).doesNotContainKeys("BODY.STATUS", "BODY.FKTARCHIVOFOTO");
        assertThat(args.body()).doesNotContainKeys("STATUS", "FKTARCHIVOFOTO");
    }

    @Test
    void unObligatorioDeCuerpoSinValorSeExigeAunqueLaBaseNoLoMarqueConBang() {
        var fila = new com.co.eurekatic.aicontrol.agente.catalogo.carga.FilaCatalogo(
                501L, "crear_x", "ESCRITURA", "d",
                "{\"BODY.TITULO\":{\"descripcion\":\"Titulo\",\"resuelve_con\":null,\"inferible\":false,\"obligatorio\":true}}",
                true, "[]", 1, null, "/planeador/actividades", "POST", "{\"BODY.TITULO\":\"VARCHAR\"}", null, List.of());
        HerramientaDef h = new com.co.eurekatic.aicontrol.agente.catalogo.carga.MapeadorHerramienta().mapear(fila);

        ResultadoValidacion sinTitulo = validador.validar(h, Map.of());

        assertThat(sinTitulo).isInstanceOf(ResultadoValidacion.Invalido.class);
        assertThat(((ResultadoValidacion.Invalido) sinTitulo).errores()).anySatisfy(e -> assertThat(e).contains("'titulo'"));
    }

    @Test
    void tipoIncorrectoSeRechazaConMensajeParaElModelo() {
        ResultadoValidacion r = validador.validar(editar, Map.of("id", "12"));

        assertThat(r).isInstanceOf(ResultadoValidacion.Invalido.class);
        assertThat(((ResultadoValidacion.Invalido) r).errores())
                .anySatisfy(e -> assertThat(e).isEqualTo("'id' debe ser un entero."));
    }

    @Test
    void unNumeroConDecimalesNoEsUnEntero() {
        ResultadoValidacion r = validador.validar(editar, Map.of("id", 12.5));

        assertThat(r).isInstanceOf(ResultadoValidacion.Invalido.class);
    }

    @Test
    void unBindDeQueryConTipoEquivocadoSeRechazaSinLlegarAlQueryService() {
        HerramientaDef lista = CatalogoFixture.actividadesMiasDef();
        ResultadoValidacion r = validador.validar(lista, Map.of("size", "5"));

        assertThat(r).isInstanceOf(ResultadoValidacion.Invalido.class);
        assertThat(((ResultadoValidacion.Invalido) r).errores()).anySatisfy(e -> assertThat(e).contains("'size'"));
    }
}
