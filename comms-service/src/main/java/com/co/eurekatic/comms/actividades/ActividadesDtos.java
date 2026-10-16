package com.co.eurekatic.comms.actividades;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.util.List;

/**
 * Formas JSON de comunicados, encuestas, elecciones y evaluaciones: iguales a
 * {@code src/features/comunicaciones/chat/api/types.ts} del front (salida en
 * camelCase) y a los cuerpos UPPER_SNAKE de sus mocks MSW (entrada).
 */
public final class ActividadesDtos {

    private ActividadesDtos() { }

    // ── comunicados ────────────────────────────────────────────────────────

    /** {@code leidos}/{@code totalDestinatarios}: confirmacion de lectura (solo con valor para el creador). */
    public record Comunicado(long conversacionId, String titulo, String descripcion, List<String> audiencia,
                             String publicarEn, String contenidoHtml, String publicadoPor, boolean esCreador,
                             Integer leidos, Integer totalDestinatarios) { }

    public record ComunicadoIn(@JsonProperty("TITULO") String titulo, @JsonProperty("DESCRIPCION") String descripcion,
                               @JsonProperty("AUDIENCIA") List<String> audiencia,
                               @JsonProperty("PUBLICAR_EN") String publicarEn,
                               @JsonProperty("CONTENIDO_HTML") String contenidoHtml) { }

    // ── encuestas ──────────────────────────────────────────────────────────

    public record OpcionEncuesta(long id, String texto, int votos) { }

    public record PreguntaEncuesta(long id, String tipo, String texto, List<OpcionEncuesta> opciones,
                                   int totalRespuestas, List<String> respuestas) { }

    public record Encuesta(long conversacionId, String nombre, String descripcion, String fechaInicio,
                           String fechaCierre, String resultados, List<PreguntaEncuesta> preguntas,
                           int totalHabilitados, int participantes, String creadoPor, boolean esCreador,
                           boolean yaRespondi) { }

    public record PreguntaEncuestaIn(@JsonProperty("ORDEN") Integer orden, @JsonProperty("TIPO") String tipo,
                                     @JsonProperty("TEXTO") String texto,
                                     @JsonProperty("OPCIONES") List<String> opciones) { }

    public record EncuestaIn(@JsonProperty("NOMBRE") String nombre, @JsonProperty("DESCRIPCION") String descripcion,
                             @JsonProperty("FECHA_INICIO") String fechaInicio,
                             @JsonProperty("FECHA_CIERRE") String fechaCierre,
                             @JsonProperty("RESULTADOS") String resultados,
                             @JsonProperty("PREGUNTAS") List<PreguntaEncuestaIn> preguntas,
                             @JsonProperty("PARTICIPANTES") List<Long> participantes) { }

    public record RespuestaIn(@JsonProperty("FK_PREGUNTA") Long pregunta, @JsonProperty("OPCIONES") List<Long> opciones,
                              @JsonProperty("TEXTO") String texto) { }

    public record RespuestasIn(@JsonProperty("RESPUESTAS") List<RespuestaIn> respuestas) { }

    // ── elecciones ─────────────────────────────────────────────────────────

    public record Candidato(long id, String nombre, String numero, String lema, String fotoUrl, int votos) { }

    public record Eleccion(long conversacionId, String nombre, String descripcion, String fechaInicio,
                           String fechaCierre, long jornadaId, boolean verResultadosEnVivo,
                           List<Candidato> candidatos, int votosEnBlanco, boolean cerradaManualmente,
                           boolean yaVoto, int totalHabilitados, int vieronCanal, String creadoPor,
                           boolean esCreador) { }

    public record CandidatoIn(@JsonProperty("NOMBRE") String nombre, @JsonProperty("NUMERO") String numero,
                              @JsonProperty("LEMA") String lema, @JsonProperty("FOTO_URL") String fotoUrl) { }

    public record EleccionIn(@JsonProperty("NOMBRE") String nombre, @JsonProperty("DESCRIPCION") String descripcion,
                             @JsonProperty("FECHA_INICIO") String fechaInicio,
                             @JsonProperty("FECHA_CIERRE") String fechaCierre,
                             @JsonProperty("FK_JORNADA") Long jornada,
                             @JsonProperty("VER_RESULTADOS") String verResultados,
                             @JsonProperty("VOTANTES") List<Long> votantes,
                             @JsonProperty("CANDIDATOS") List<CandidatoIn> candidatos) { }

    public record VotoIn(@JsonProperty("FK_CANDIDATO") Long candidato) { }

    public record OpcionesVotantes(List<String> grados, List<String> funcionarios) { }

    public record Votante(long id, String nombre, String documento, int numero) { }

    public record VotantesIn(@JsonProperty("GRUPO") String grupo, @JsonProperty("VALOR") String valor) { }

    // ── evaluaciones ───────────────────────────────────────────────────────

    public record OpcionEvaluacion(long id, String texto, boolean correcta) { }

    public record PreguntaEvaluacion(long id, String tipo, String texto, BigDecimal puntos,
                                     List<OpcionEvaluacion> opciones) { }

    public record Evaluacion(long conversacionId, String nombre, String descripcion, String fechaInicio,
                             String fechaCierre, Integer tiempoLimiteMin, BigDecimal puntajeTotal, Integer intentos,
                             String mostrarResultados, List<PreguntaEvaluacion> preguntas, String creadoPor,
                             boolean esCreador, int intentosUsados, BigDecimal miNota, boolean miNotaPendiente) { }

    public record RespuestaEntrega(long preguntaId, List<Long> opcionIds, String texto, BigDecimal puntos) { }

    public record EntregaEvaluacion(long id, String estudiante, String estado, List<RespuestaEntrega> respuestas) { }

    public record OpcionEvaluacionIn(@JsonProperty("TEXTO") String texto, @JsonProperty("CORRECTA") String correcta) { }

    public record PreguntaEvaluacionIn(@JsonProperty("ORDEN") Integer orden, @JsonProperty("TIPO") String tipo,
                                       @JsonProperty("TEXTO") String texto,
                                       @JsonProperty("PUNTOS") BigDecimal puntos,
                                       @JsonProperty("OPCIONES") List<OpcionEvaluacionIn> opciones) { }

    public record EvaluacionIn(@JsonProperty("NOMBRE") String nombre, @JsonProperty("DESCRIPCION") String descripcion,
                               @JsonProperty("FECHA_INICIO") String fechaInicio,
                               @JsonProperty("FECHA_CIERRE") String fechaCierre,
                               @JsonProperty("TIEMPO_LIMITE_MIN") Integer tiempoLimiteMin,
                               @JsonProperty("PUNTAJE_TOTAL") BigDecimal puntajeTotal,
                               @JsonProperty("INTENTOS") Integer intentos,
                               @JsonProperty("MOSTRAR_RESULTADOS") String mostrarResultados,
                               @JsonProperty("PREGUNTAS") List<PreguntaEvaluacionIn> preguntas,
                               @JsonProperty("PARTICIPANTES") List<Long> participantes) { }

    public record CalificacionIn(@JsonProperty("FK_PREGUNTA") Long pregunta, @JsonProperty("PUNTOS") BigDecimal puntos) { }

    public record CalificarIn(@JsonProperty("CALIFICACIONES") List<CalificacionIn> calificaciones) { }
}
