package com.co.eurekatic.aicontrol.agente.catalogo.turno;

import java.util.Map;

/** Puerto: los menus del usuario, por codigo de menu, con su nivel de acceso. */
public interface MenusUsuario {

    /**
     * @param bearer token del usuario
     * @return menus visibles por codigo; vacio si no se pueden obtener (el turno se queda sin
     *         herramientas de datos, no con todas)
     */
    Map<String, AccesoMenu> de(String bearer);
}
