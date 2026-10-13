package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class VerificadorIdsPresenciaTest {

    private static final HerramientaDef LECTURA = herramienta(TipoHerramienta.LECTURA);
    private static final HerramientaDef ESCRITURA = herramienta(TipoHerramienta.ESCRITURA);

    @Test
    void conElRegistroCaidoUnaLecturaPasaPeroUnaEscrituraNo() {
        assertThat(VerificadorIds.admite(RegistroIds.Presencia.DESCONOCIDO, LECTURA)).isTrue();
        assertThat(VerificadorIds.admite(RegistroIds.Presencia.DESCONOCIDO, ESCRITURA)).isFalse();
    }

    @Test
    void visto_y_noVistoDecidenIgualParaTodos() {
        assertThat(VerificadorIds.admite(RegistroIds.Presencia.VISTO, ESCRITURA)).isTrue();
        assertThat(VerificadorIds.admite(RegistroIds.Presencia.NO_VISTO, LECTURA)).isFalse();
    }

    private static HerramientaDef herramienta(TipoHerramienta tipo) {
        return new HerramientaDef(1L, "h", tipo, "d", List.of(), tipo.escribe(), List.of(), 1,
                Optional.empty(), Optional.empty(), Set.of());
    }
}
