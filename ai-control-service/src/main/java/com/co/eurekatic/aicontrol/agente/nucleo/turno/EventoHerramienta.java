package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import java.util.Objects;

/**
 * Inicio o fin de una herramienta en el turno, para el streaming. No lleva argumentos ni resultado: solo
 * lo que la persona puede ver ("Consultando sedes").
 *
 * @param id          identificador de la llamada dentro del turno; une su INICIO con su FIN
 * @param herramienta codigo de la herramienta del catalogo
 * @param etiqueta    texto en espanol para la persona
 * @param fase        INICIO o FIN
 * @param ok          en FIN, si termino sin error; null en INICIO
 */
public record EventoHerramienta(String id, String herramienta, String etiqueta, Fase fase, Boolean ok) {

    public enum Fase { INICIO, FIN }

    public EventoHerramienta {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(herramienta, "herramienta");
        Objects.requireNonNull(etiqueta, "etiqueta");
        Objects.requireNonNull(fase, "fase");
    }

    public static EventoHerramienta inicio(String id, String herramienta) {
        return new EventoHerramienta(id, herramienta, EtiquetasHerramientas.de(herramienta), Fase.INICIO, null);
    }

    public static EventoHerramienta fin(String id, String herramienta, boolean ok) {
        return new EventoHerramienta(id, herramienta, EtiquetasHerramientas.de(herramienta), Fase.FIN, ok);
    }
}
