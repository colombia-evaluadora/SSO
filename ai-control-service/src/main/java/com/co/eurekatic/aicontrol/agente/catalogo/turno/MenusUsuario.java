package com.co.eurekatic.aicontrol.agente.catalogo.turno;

import java.util.Map;

/** Puerto: los menus del usuario, por codigo de menu, con su nivel de acceso. */
public interface MenusUsuario {

    /**
     * @param userId id de {@code public.users} del JWT (claim {@code uid})
     * @return menus visibles por codigo; vacio si no se pueden obtener (el turno se queda sin
     *         herramientas de datos, no con todas)
     */
    Map<String, AccesoMenu> de(long userId);
}
