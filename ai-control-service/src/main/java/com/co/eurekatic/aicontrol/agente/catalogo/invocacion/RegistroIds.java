package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import java.util.List;
import java.util.Map;

/**
 * Puerto: ids que el modelo ya ha visto en la conversacion. Un argumento que es id solo
 * vale si salio de un resultado previo; asi el modelo no inventa pks.
 */
public interface RegistroIds {

    /** Si el registro conoce un id en la conversacion; {@code DESCONOCIDO} cuando el almacen no responde. */
    enum Presencia {
        VISTO,
        NO_VISTO,
        DESCONOCIDO
    }

    /** Guarda los ids visibles en un resultado de la conversacion. */
    void registrar(String conversationId, List<Map<String, Object>> filas);

    /** Presencia del id en la conversacion; quien pregunta decide que hacer si es desconocida. */
    Presencia consultar(String conversationId, String id);

    /**
     * Presencia del id como id de esa entidad. Si la conversacion ya vio ids de la entidad, el id tiene que ser
     * uno de ellos (un grado no vale como grupo); si no vio ninguno, cuenta la presencia sin tipo.
     */
    Presencia consultarDe(String conversationId, String entidad, String id);
}
