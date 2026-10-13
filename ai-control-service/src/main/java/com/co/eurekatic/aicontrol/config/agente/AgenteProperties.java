package com.co.eurekatic.aicontrol.config.agente;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;

import java.time.Duration;
import java.util.List;
import java.util.Objects;

/**
 * Calibracion del agente conversacional, agrupada por tema. Cada valor sale de
 * {@code sso.ai.agente.*} en application.yml, con su variable de entorno. Lo
 * comun al proveedor (base-url, api-key) sigue en {@code spring.ai.openai.*}.
 *
 * @param modelos  rapido (clasifica y redacta) y razonador (planea y elige herramientas)
 * @param limites  presupuesto de herramientas por turno y tope de peticiones
 * @param memoria  ventana que ve el modelo y vida de la memoria en Redis
 * @param acciones plazo para confirmar una accion de escritura
 * @param catalogo catalogo de herramientas: refresco, permisos de menu y tamano de los resultados
 */
@ConfigurationProperties("sso.ai.agente")
public record AgenteProperties(
        Modelos modelos,
        @DefaultValue Limites limites,
        @DefaultValue Memoria memoria,
        @DefaultValue Acciones acciones,
        @DefaultValue Catalogo catalogo) {

    public AgenteProperties {
        Objects.requireNonNull(modelos, "sso.ai.agente.modelos es obligatorio");
    }

    /**
     * @param rapido    sin razonamiento; nunca ejecuta herramientas de escritura
     * @param razonador planea y elige herramientas
     */
    public record Modelos(Modelo rapido, Modelo razonador) {
    }

    /**
     * Un modelo del proveedor. Mismo proveedor y cuenta para los dos: solo cambian
     * el modelo y su presupuesto.
     *
     * @param nombre        identificador del modelo en el proveedor
     * @param extraBodyJson campos extra del proveedor, como JSON (modo de razonamiento)
     * @param maxTokens     tope de tokens de salida; en el razonador incluye los de razonamiento
     */
    public record Modelo(String nombre, String extraBodyJson, int maxTokens) {

        public Modelo {
            Objects.requireNonNull(nombre, "nombre del modelo es obligatorio");
            if (maxTokens <= 0) {
                throw new IllegalArgumentException("maxTokens debe ser positivo");
            }
        }
    }

    /**
     * @param maxTotalToolCalls      llamadas a herramientas por turno, en total
     * @param maxCallsPorHerramienta llamadas a una misma herramienta por turno
     * @param rateLimitUsuarioPorMin turnos por minuto y por usuario
     * @param textoMaxCaracteres     longitud maxima de un mensaje del usuario
     * @param maxConcurrentRazonador llamadas simultaneas al razonador por instancia
     */
    public record Limites(
            @DefaultValue("15") int maxTotalToolCalls,
            @DefaultValue("5") int maxCallsPorHerramienta,
            @DefaultValue("20") int rateLimitUsuarioPorMin,
            @DefaultValue("4000") int textoMaxCaracteres,
            @DefaultValue("2") int maxConcurrentRazonador) {
    }

    /**
     * @param maxMensajes mensajes de la conversacion que ve el modelo
     * @param ttl         vida de la memoria en Redis desde la ultima escritura
     */
    public record Memoria(@DefaultValue("30") int maxMensajes, @DefaultValue("24h") Duration ttl) {
    }

    /** @param expira cuanto espera una accion de escritura su confirmacion */
    public record Acciones(@DefaultValue("10m") Duration expira) {
    }

    /**
     * @param refresco       cada cuanto se relee el catalogo de la base cuando todo va bien
     * @param reintento      cada cuanto se reintenta si el catalogo esta vacio o la base no responde
     * @param menusTtl       vida de los menus del usuario en memoria (por id de usuario)
     * @param maxFilas       filas que ve el modelo de un resultado; el resto se corta y se marca
     * @param maxCaracteres  caracteres que ve el modelo de un resultado serializado
     * @param columnasSensibles fragmentos de nombre de columna que no salen hacia el modelo (sin
     *                       distinguir mayusculas); los ids y los nombres se conservan siempre
     */
    public record Catalogo(
            @DefaultValue("PT5M") Duration refresco,
            @DefaultValue("PT30S") Duration reintento,
            @DefaultValue("60s") Duration menusTtl,
            @DefaultValue("50") int maxFilas,
            @DefaultValue("12000") int maxCaracteres,
            @DefaultValue({"identificacion", "documento", "correo", "email", "telefono", "celular",
                    "direccion", "fecha_nacimiento", "password", "contrasena", "token"})
            List<String> columnasSensibles) {

        public Catalogo {
            if (maxFilas <= 0 || maxCaracteres <= 0) {
                throw new IllegalArgumentException("maxFilas y maxCaracteres deben ser positivos");
            }
            columnasSensibles = List.copyOf(columnasSensibles);
        }
    }
}
