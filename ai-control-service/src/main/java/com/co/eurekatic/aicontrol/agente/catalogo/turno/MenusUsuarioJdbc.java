package com.co.eurekatic.aicontrol.agente.catalogo.turno;

import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import java.time.Clock;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * Adaptador JDBC de {@link MenusUsuario}: lee {@code ai.fn_menus_usuario_interno(:uid)} y cachea
 * el resultado {@code menusTtl} por id de usuario. Un fallo de base no se cachea y deja el turno
 * sin herramientas de datos (fail-closed).
 */
@Component
public class MenusUsuarioJdbc implements MenusUsuario {

    private static final Logger log = LoggerFactory.getLogger(MenusUsuarioJdbc.class);
    private static final String SQL_MENUS = """
            SELECT codigo, puede_ver, puede_crear, puede_editar, puede_eliminar
              FROM ai.fn_menus_usuario_interno(:uid)
            """;

    private final JdbcClient jdbc;
    private final CacheMenus<Long> cache;

    public MenusUsuarioJdbc(JdbcClient jdbc, AgenteProperties props) {
        this.jdbc = jdbc;
        this.cache = new CacheMenus<>(props.catalogo().menusTtl(), Clock.systemUTC());
    }

    @Override
    public Map<String, AccesoMenu> de(long userId) {
        Optional<Map<String, AccesoMenu>> enCache = cache.obtener(userId);
        if (enCache.isPresent()) {
            return enCache.get();
        }
        try {
            List<FilaMenu> filas = jdbc.sql(SQL_MENUS)
                    .param("uid", userId)
                    .query((rs, n) -> new FilaMenu(
                            rs.getString("codigo"),
                            rs.getBoolean("puede_ver"),
                            rs.getBoolean("puede_crear"),
                            rs.getBoolean("puede_editar"),
                            rs.getBoolean("puede_eliminar")))
                    .list();
            Map<String, AccesoMenu> menus = MapeadorMenus.desde(filas);
            cache.poner(userId, menus);
            return menus;
        } catch (DataAccessException e) {
            log.warn("Menus del usuario no disponibles ({}): el turno no tendra herramientas de datos",
                    e.getClass().getSimpleName());
            return Map.of();
        }
    }
}
