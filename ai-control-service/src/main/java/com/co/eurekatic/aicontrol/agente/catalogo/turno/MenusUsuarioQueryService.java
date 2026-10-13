package com.co.eurekatic.aicontrol.agente.catalogo.turno;

import com.co.eurekatic.aicontrol.agente.comun.Huellas;
import com.co.eurekatic.aicontrol.client.QueryServiceClient;
import com.co.eurekatic.aicontrol.client.RespuestaQuery;
import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpMethod;
import org.springframework.stereotype.Component;

import java.time.Clock;
import java.util.Map;
import java.util.Optional;

/**
 * Adaptador de {@link MenusUsuario}: pide los menus del usuario a query-service con su propio
 * token y los cachea un ttl por hash del token. Un fallo no se cachea.
 */
@Component
public class MenusUsuarioQueryService implements MenusUsuario {

    private static final Logger log = LoggerFactory.getLogger(MenusUsuarioQueryService.class);

    private final QueryServiceClient queryService;
    private final String ruta;
    private final CacheMenus cache;

    public MenusUsuarioQueryService(QueryServiceClient queryService, AgenteProperties props) {
        this.queryService = queryService;
        this.ruta = props.catalogo().rutaMenus();
        this.cache = new CacheMenus(props.catalogo().menusTtl(), Clock.systemUTC());
    }

    @Override
    public Map<String, AccesoMenu> de(String bearer) {
        String clave = Huellas.sha256(bearer);
        Optional<Map<String, AccesoMenu>> enCache = cache.obtener(clave);
        if (enCache.isPresent()) {
            return enCache.get();
        }
        RespuestaQuery respuesta = queryService.invocar(HttpMethod.GET, ruta, Map.of(), Map.of(), bearer);
        return switch (respuesta) {
            case RespuestaQuery.Exito exito -> {
                Map<String, AccesoMenu> menus = MapeadorMenus.desde(exito.filas());
                cache.poner(clave, menus);
                yield menus;
            }
            case RespuestaQuery.ErrorCliente error -> {
                log.warn("Menus del usuario no disponibles (HTTP {}): el turno no tendra herramientas de datos",
                        error.status());
                yield Map.of();
            }
            case RespuestaQuery.ErrorServidor _ -> {
                log.warn("Menus del usuario no disponibles (servicio): el turno no tendra herramientas de datos");
                yield Map.of();
            }
        };
    }
}
