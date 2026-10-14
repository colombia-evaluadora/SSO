package com.co.eurekatic.aicontrol.agente.comun;

import java.time.Duration;

/**
 * Errores de dominio del agente. El controller los traduce a HTTP en un solo sitio; los mensajes
 * son para el usuario y no llevan detalles internos.
 */
public abstract sealed class ErrorAgente extends RuntimeException
        permits ErrorAgente.ConversacionNoEncontrada, ErrorAgente.ConversacionCerrada,
        ErrorAgente.AccionNoEncontrada, ErrorAgente.AccionNoPendiente, ErrorAgente.AccionExpirada,
        ErrorAgente.AccionAlterada, ErrorAgente.LimiteExcedido, ErrorAgente.SinIdentidad,
        ErrorAgente.PeticionInvalida, ErrorAgente.TurnoEnCurso {

    protected ErrorAgente(String mensaje) {
        super(mensaje);
    }

    /** La conversacion no existe o es de otro usuario: ambos casos se tratan igual. */
    public static final class ConversacionNoEncontrada extends ErrorAgente {
        public ConversacionNoEncontrada() {
            super("La conversación no existe.");
        }
    }

    /** La conversacion esta archivada o bloqueada y no admite mensajes nuevos. */
    public static final class ConversacionCerrada extends ErrorAgente {
        public ConversacionCerrada() {
            super("La conversación está archivada. Crea una nueva para seguir.");
        }
    }

    public static final class AccionNoEncontrada extends ErrorAgente {
        public AccionNoEncontrada() {
            super("La acción no existe.");
        }
    }

    /** La accion ya se resolvio (confirmada, cancelada, expirada o en ejecucion). */
    public static final class AccionNoPendiente extends ErrorAgente {
        public AccionNoPendiente() {
            super("La acción ya no está pendiente: se resolvió o se está ejecutando.");
        }
    }

    public static final class AccionExpirada extends ErrorAgente {
        public AccionExpirada() {
            super("La acción expiró. Vuelve a pedirla.");
        }
    }

    /** El payload guardado ya no coincide con su huella: no se ejecuta. */
    public static final class AccionAlterada extends ErrorAgente {
        public AccionAlterada() {
            super("La acción cambió después de prepararse y no se ejecutó. Vuelve a pedirla.");
        }
    }

    public static final class LimiteExcedido extends ErrorAgente {

        private final Duration reintentoEn;

        public LimiteExcedido(Duration reintentoEn) {
            super("Has enviado demasiados mensajes seguidos. Espera un momento.");
            this.reintentoEn = reintentoEn;
        }

        public Duration reintentoEn() {
            return reintentoEn;
        }
    }

    public static final class SinIdentidad extends ErrorAgente {
        public SinIdentidad() {
            super("La sesión no tiene identidad de usuario.");
        }
    }

    public static final class PeticionInvalida extends ErrorAgente {
        public PeticionInvalida(String mensaje) {
            super(mensaje);
        }
    }

    /** El usuario ya tiene un turno en marcha: uno a la vez, para no acaparar el modelo ni pisar la memoria. */
    public static final class TurnoEnCurso extends ErrorAgente {
        public TurnoEnCurso() {
            super("Todavía estoy respondiendo tu mensaje anterior. Espera a que termine.");
        }
    }
}
