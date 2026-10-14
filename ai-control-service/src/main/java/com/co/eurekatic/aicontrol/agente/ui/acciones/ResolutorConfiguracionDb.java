package com.co.eurekatic.aicontrol.agente.ui.acciones;

import com.co.eurekatic.aicontrol.agente.catalogo.carga.CatalogoHerramientasLoader;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ArgumentosCanonicos;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ConstructorPeticion;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.Peticion;
import com.co.eurekatic.aicontrol.agente.ui.contexto.FormularioUi;
import com.co.eurekatic.aicontrol.agente.ui.registro.FormularioRegistrado;
import com.co.eurekatic.aicontrol.client.QueryServiceClient;
import com.co.eurekatic.aicontrol.client.RespuestaQuery;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.Map;
import java.util.Optional;

/**
 * Obtiene la configuracion de un formulario gestionado por la base llamando a su herramienta de lectura
 * con el token del usuario: el gate de esa ruta decide igual que en la pantalla. No pasa por el modelo
 * ni por la regla de ids, porque el id no lo eligio el modelo sino la pantalla abierta.
 *
 * <p>Vacio si no se pudo obtener: quien la usa no deja rellenar ese formulario (fallo cerrado).
 */
@Component
public class ResolutorConfiguracionDb {

    private static final Logger log = LoggerFactory.getLogger(ResolutorConfiguracionDb.class);
    private static final String PARAM_ID = "PARAM.ID";

    private final CatalogoHerramientasLoader catalogo;
    private final QueryServiceClient queryService;

    public ResolutorConfiguracionDb(CatalogoHerramientasLoader catalogo, QueryServiceClient queryService) {
        this.catalogo = catalogo;
        this.queryService = queryService;
    }

    public Optional<ConfiguracionCamposDb> resolver(FormularioRegistrado registrado, FormularioUi abierto,
                                                    String bearer) {
        Optional<String> entidad = abierto.entidadId();
        if (entidad.isEmpty()) {
            return Optional.of(ConfiguracionCamposDb.sinRestricciones());
        }
        Optional<RutaQuery> ruta = registrado.fuenteDeCampos()
                .flatMap(codigo -> catalogo.catalogo().buscar(codigo))
                .flatMap(HerramientaDef::ruta);
        if (ruta.isEmpty()) {
            log.warn("Formulario {} sin herramienta de configuracion en el catalogo", registrado.codigo());
            return Optional.empty();
        }
        Peticion peticion = ConstructorPeticion.construir(ruta.get(),
                new ArgumentosCanonicos(Map.of(PARAM_ID, entidad.get())));
        return switch (queryService.invocar(peticion.metodo(), peticion.ruta(), peticion.query(), peticion.body(), bearer)) {
            case RespuestaQuery.Exito exito -> Optional.of(ConfiguracionCamposDb.desde(exito.filas()));
            case RespuestaQuery.ErrorCliente error -> {
                log.info("Configuracion del formulario {} rechazada: {}", registrado.codigo(), error.status());
                yield Optional.empty();
            }
            case RespuestaQuery.ErrorServidor _ -> Optional.empty();
        };
    }
}
