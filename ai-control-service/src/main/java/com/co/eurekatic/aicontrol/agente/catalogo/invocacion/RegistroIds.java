package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import java.util.List;
import java.util.Map;

/**
 * Puerto: ids que el modelo ya ha visto en la conversacion. Un argumento que es id solo
 * vale si salio de un resultado previo; asi el modelo no inventa pks.
 */
public interface RegistroIds {

    /** Guarda los ids visibles en un resultado de la conversacion. */
    void registrar(String conversationId, List<Map<String, Object>> filas);

    /**
     * @return si el id aparecio antes en la conversacion. Si el almacen no responde, se
     *         permite: la base sigue siendo la autoridad y el gate se aplica igual.
     */
    boolean contiene(String conversationId, String id);
}
