package com.co.eurekatic.aicontrol.agente.catalogo.carga;

import java.util.List;

/** Puerto: lee las herramientas activas tal como estan en la base. */
public interface CatalogoRepository {

    /**
     * @throws org.springframework.dao.DataAccessException si la base no responde
     */
    List<FilaCatalogo> leerActivas();
}
