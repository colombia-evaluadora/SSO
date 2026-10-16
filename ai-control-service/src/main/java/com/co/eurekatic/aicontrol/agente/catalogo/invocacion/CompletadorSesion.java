package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ValorDeSesion;
import com.co.eurekatic.aicontrol.agente.persistencia.identidad.IdentidadAcademica;
import org.springframework.stereotype.Component;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;

/**
 * Pone desde la sesion los parametros {@code de_sesion} que el modelo no mando. Lo que el modelo si mando se
 * respeta (ya paso la regla de ids); lo que se pone aqui sale del servidor, no del modelo, asi que no pasa por
 * esa regla. Si la sesion no tiene el valor, el parametro se queda sin mandar y decide la ruta.
 */
@Component
public class CompletadorSesion {

    private final IdentidadAcademica identidad;

    public CompletadorSesion(IdentidadAcademica identidad) {
        this.identidad = identidad;
    }

    public ArgumentosCanonicos completar(HerramientaDef herramienta, ArgumentosCanonicos argumentos, long userId) {
        Map<String, Object> planos = new LinkedHashMap<>(argumentos.planos());
        boolean cambio = false;
        for (ParametroDef parametro : herramienta.parametros()) {
            if (parametro.deSesion().isEmpty() || planos.containsKey(parametro.clave())) {
                continue;
            }
            Optional<Long> valor = valor(parametro.deSesion().get(), userId);
            if (valor.isPresent()) {
                planos.put(parametro.clave(), valor.get());
                cambio = true;
            }
        }
        return cambio ? new ArgumentosCanonicos(planos) : argumentos;
    }

    private Optional<Long> valor(ValorDeSesion deSesion, long userId) {
        return switch (deSesion) {
            case FUNCIONARIO -> identidad.funcionario(userId);
        };
    }
}
