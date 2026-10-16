package com.co.eurekatic.aicontrol.agente.ui.sugerencias;

import java.util.List;
import java.util.Objects;
import java.util.Optional;

/**
 * Mensajes de ejemplo por menu, para que la persona sepa que pedirle al asistente en la pantalla en que
 * esta. Cada uno declara el tipo de herramienta que necesita: solo se ofrece si el usuario puede usar
 * alguna de ese tipo en ese menu (una sugerencia que acaba en "no tienes permiso" no ayuda).
 */
public final class CatalogoSugerencias {

    /** Lo que necesita una sugerencia para poder cumplirse. */
    public enum Tipo {
        /** Una herramienta de lectura o analitica del menu. */
        CONSULTA,
        /** Una herramienta de escritura del menu, sin solo lectura. */
        ACCION,
        /** Alguna pantalla visible para el usuario. */
        NAVEGACION,
        /** Nada: ayuda general sobre el asistente. */
        AYUDA
    }

    /**
     * @param menuCodigo menu al que pertenece; vacio si es general (se ofrece en cualquier pantalla)
     */
    public record Sugerencia(Optional<String> menuCodigo, String texto, Tipo tipo) {

        public Sugerencia {
            Objects.requireNonNull(menuCodigo, "menuCodigo");
            Objects.requireNonNull(texto, "texto");
            Objects.requireNonNull(tipo, "tipo");
        }
    }

    private static final List<Sugerencia> TODAS = List.of(
            de("FUNCIONARIOS", "¿Cuántos funcionarios activos hay en mi sede?", Tipo.CONSULTA),
            de("FUNCIONARIOS", "Muéstrame los docentes de la jornada de la mañana", Tipo.CONSULTA),
            de("FUNCIONARIOS", "Cambia el cargo de un funcionario", Tipo.ACCION),
            de("SEDES_EDUCATIVAS", "¿Qué sedes tiene el establecimiento?", Tipo.CONSULTA),
            de("SEDES_EDUCATIVAS", "¿Qué jornadas están activas en cada sede?", Tipo.CONSULTA),
            de("PERIODOS_ACADEMICOS", "¿Cuál es el periodo académico vigente?", Tipo.CONSULTA),
            de("PERIODOS_ACADEMICOS", "Lista los años lectivos", Tipo.CONSULTA),
            de("ESTABLECIMIENTO_EDUCATIVO", "Muéstrame los establecimientos a los que tengo acceso", Tipo.CONSULTA),
            de("PLANEADOR", "¿Qué actividades tengo esta semana?", Tipo.CONSULTA),
            de("PLANEADOR", "Muéstrame las unidades temáticas de mi asignatura", Tipo.CONSULTA),
            de("PLANEADOR", "¿Cuántas actividades tengo por calificar?", Tipo.CONSULTA),
            de("PLANEADOR", "Crea una actividad evaluativa para mi grupo", Tipo.ACCION),
            de("PLANEADOR", "Califica a un estudiante en una actividad", Tipo.ACCION),
            de("REFERENTES_CURRICULARES", "Lista los referentes curriculares", Tipo.CONSULTA),
            de("REFERENTES_CURRICULARES", "¿Qué enunciados tiene un referente curricular?", Tipo.CONSULTA),
            general("¿Qué puedo hacer desde el asistente?", Tipo.AYUDA),
            general("¿Dónde registro la asistencia?", Tipo.NAVEGACION),
            general("Llévame a la pantalla de funcionarios", Tipo.NAVEGACION));

    private CatalogoSugerencias() {
    }

    public static List<Sugerencia> todas() {
        return TODAS;
    }

    private static Sugerencia de(String menu, String texto, Tipo tipo) {
        return new Sugerencia(Optional.of(menu), texto, tipo);
    }

    private static Sugerencia general(String texto, Tipo tipo) {
        return new Sugerencia(Optional.empty(), texto, tipo);
    }
}
