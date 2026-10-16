package com.co.eurekatic.comms.actividades;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.util.List;
import java.util.Map;

/**
 * Matriz de roles de las actividades del chat ({@code comms.actividades.*}).
 * Mismos perfiles que la politica de directos ({@code PoliticaChat.perfil}).
 *
 * @param crean     perfiles que crean cada actividad (COMUNICADO, ENCUESTA, ELECCION, EVALUACION).
 *                  Estudiantes y acudientes nunca crean: no se aceptan aqui aunque se configuren.
 * @param audiencia rol del SSO (sin prefijo CEVAL-) → audiencia del comunicado.
 * @param avisosMs  cada cuanto se revisan comunicados programados y actividades que abren.
 */
@ConfigurationProperties(prefix = "comms.actividades")
public record ActividadesProperties(Map<String, List<String>> crean, Map<String, List<String>> audiencia,
                                    Long avisosMs) {

    public ActividadesProperties {
        if (crean == null || crean.isEmpty()) {
            crean = Map.of(
                    "COMUNICADO", List.of("DIRECTIVO"),
                    "ENCUESTA", List.of("DIRECTIVO", "DOCENTE"),
                    "ELECCION", List.of("DIRECTIVO"),
                    "EVALUACION", List.of("DIRECTIVO", "DOCENTE"));
        }
        if (audiencia == null || audiencia.isEmpty()) {
            audiencia = Map.of(
                    "ESTUDIANTES", List.of("ESTUDIANTE"),
                    "PADRES", List.of("ACUDIENTE"),
                    "DOCENTES", List.of("DOCENTE", "DIRECTOR_GRUPO"),
                    "DIRECTIVOS", List.of("RECTOR", "COORDINADOR"),
                    "ADMINISTRATIVOS", List.of("AUXILIAR_ADMINISTRATIVO", "PSICO_ORIENTADOR", "JEFE_AREA",
                            "JEFE_AREA_CALIDAD", "JEFE_AREA_COBERTURA", "JEFE_AREA_PLANEACION",
                            "JEFE_SISTEMA_ESTABLECIMIENTO"));
        }
        if (avisosMs == null || avisosMs <= 0) avisosMs = 30_000L;
    }
}
