package com.co.eurekatic.aicontrol.agente.catalogo.carga;

import com.co.eurekatic.aicontrol.agente.catalogo.CatalogoFixture;
import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import com.co.eurekatic.aicontrol.agente.comun.PropiedadesAgenteFixture;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataAccessResourceFailureException;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class CatalogoHerramientasLoaderTest {

    private static final Clock RELOJ = Clock.fixed(Instant.parse("2026-10-13T12:00:00Z"), ZoneOffset.UTC);

    @Test
    void cargaSoloLasHerramientasQueSuperanMapeoYTecho() {
        FilaCatalogo rota = new FilaCatalogo(201L, "borrar_todo", "LECTURA", "d", "{}", false, "[]", 1,
                "FUNCIONARIOS", "/usuarios/:ID/eliminar", "DELETE", "{}", null, List.of());
        FilaCatalogo rota2 = new FilaCatalogo(202L, "sin_tipo", "LECTURA", "d",
                "{\"BODY.X\":{\"descripcion\":\"x\",\"resuelve_con\":null,\"inferible\":false}}",
                false, "[]", 1, "FUNCIONARIOS", "/planeador/actividades", "POST", "{}", null, List.of());
        CatalogoRepositorioFalso repo = new CatalogoRepositorioFalso(
                List.of(CatalogoFixture.editarFuncionario(), rota, rota2));
        CatalogoHerramientasLoader loader = loader(repo);

        loader.refrescar();

        assertThat(loader.catalogo().todas()).extracting(h -> h.codigo()).containsExactly("editar_funcionario");
    }

    @Test
    void siLaBaseNoRespondeElCatalogoQuedaVacioSinLanzar() {
        CatalogoRepositorioFalso repo = new CatalogoRepositorioFalso(null);
        CatalogoHerramientasLoader loader = loader(repo);

        loader.refrescar();

        assertThat(loader.catalogo().estaVacio()).isTrue();
    }

    @Test
    void unFalloAlRelerConservaElCatalogoAnterior() {
        CatalogoRepositorioFalso repo = new CatalogoRepositorioFalso(List.of(CatalogoFixture.editarFuncionario()));
        CatalogoHerramientasLoader loader = loader(repo);
        loader.refrescar();

        repo.fallar = true;
        loader.refrescar();

        assertThat(loader.catalogo().tamano()).isEqualTo(1);
    }

    @Test
    void conCatalogoVacioSeReintentaAunqueNoHayaVencidoElRefresco() {
        Instant ahora = Instant.parse("2026-10-13T12:00:00Z");
        assertThat(CatalogoHerramientasLoader.debeRefrescar(true, ahora, ahora, Duration.ofMinutes(5))).isTrue();
    }

    @Test
    void conCatalogoCargadoSeRefrescaSoloPasadoElPeriodo() {
        Instant ultima = Instant.parse("2026-10-13T12:00:00Z");
        assertThat(CatalogoHerramientasLoader.debeRefrescar(false, ultima, ultima.plusSeconds(60), Duration.ofMinutes(5)))
                .isFalse();
        assertThat(CatalogoHerramientasLoader.debeRefrescar(false, ultima, ultima.plusSeconds(300), Duration.ofMinutes(5)))
                .isTrue();
    }

    private static CatalogoHerramientasLoader loader(CatalogoRepository repo) {
        AgenteProperties props = PropiedadesAgenteFixture.propiedades();
        return new CatalogoHerramientasLoader(repo, new MapeadorHerramienta(), new TechoHerramientas(),
                props.catalogo(), RELOJ);
    }

    /** Repositorio en memoria: lista fija, o un fallo de base si {@code fallar} o la lista es null. */
    private static final class CatalogoRepositorioFalso implements CatalogoRepository {
        private final List<FilaCatalogo> filas;
        boolean fallar;

        CatalogoRepositorioFalso(List<FilaCatalogo> filas) {
            this.filas = filas == null ? null : new ArrayList<>(filas);
            this.fallar = filas == null;
        }

        @Override
        public List<FilaCatalogo> leerActivas() {
            if (fallar) {
                throw new DataAccessResourceFailureException("base caida");
            }
            return filas;
        }
    }
}
