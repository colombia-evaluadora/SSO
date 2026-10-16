package com.co.eurekatic.aicontrol.agente.nucleo.respuesta;

import com.co.eurekatic.aicontrol.agente.web.dto.RespuestaDto;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.json.JsonMapper;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/** El contrato con el front: cada accion de UI sale con su tipo en {@code op}. */
class AccionUiJsonTest {

    private final JsonMapper json = JsonMapper.builder().build();

    @Test
    void lasAccionesSeSerializanConSuOp() {
        RespuestaAgente.Ui ui = new RespuestaAgente.Ui("Te llevé al formulario.", List.of(
                new AccionUi.Navegar("funcionarios", "/app/establecimiento-educativo/funcionarios", Map.of()),
                new AccionUi.Rellenar("funcionario.crear", Map.of("nombres", "Ana")),
                new AccionUi.Resaltar("funcionario.crear", "numeroDocumento")));

        String salida = json.writeValueAsString(RespuestaDto.de(ui));

        assertThat(salida).contains("\"tipo\":\"UI\"", "\"op\":\"NAVEGAR\"", "\"op\":\"RELLENAR\"",
                "\"op\":\"RESALTAR\"", "\"url\":\"/app/establecimiento-educativo/funcionarios\"")
                .doesNotContain("ENVIAR");
    }
}
