package com.co.eurekatic.aicontrol.agente.nucleo.respuesta;

import com.co.eurekatic.aicontrol.agente.nucleo.AccionPropuesta;
import com.co.eurekatic.aicontrol.agente.nucleo.Faltante;

import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.function.UnaryOperator;

/**
 * Lo que el agente devuelve a la persona en un turno. Cerrado: cada caso tiene su tipo y su forma.
 * Todos los textos son para el usuario, en espanol y sin detalles internos.
 */
public sealed interface RespuestaAgente
        permits RespuestaAgente.Respuesta, RespuestaAgente.Pregunta, RespuestaAgente.Confirmacion,
        RespuestaAgente.Ui, RespuestaAgente.Datos, RespuestaAgente.Bloqueado, RespuestaAgente.SinPermiso {

    String texto();

    TipoRespuesta tipo();

    /** Copia con los textos transformados (salida segura: redaccion o sustitucion). */
    RespuestaAgente transformarTextos(UnaryOperator<String> transformacion);

    /** Respuesta de texto simple. */
    record Respuesta(String texto) implements RespuestaAgente {

        public Respuesta {
            Objects.requireNonNull(texto, "texto");
        }

        @Override
        public TipoRespuesta tipo() {
            return TipoRespuesta.RESPUESTA;
        }

        @Override
        public RespuestaAgente transformarTextos(UnaryOperator<String> transformacion) {
            return new Respuesta(transformacion.apply(texto));
        }
    }

    /**
     * Faltan datos para una accion. El turno termina; la respuesta llega en el siguiente mensaje.
     *
     * @param faltantes preguntas al usuario, en orden
     * @param borrador  lo que ya se sabe de la accion, para no volver a pedirlo
     */
    record Pregunta(String texto, List<Faltante> faltantes, Map<String, Object> borrador) implements RespuestaAgente {

        public Pregunta {
            Objects.requireNonNull(texto, "texto");
            faltantes = List.copyOf(faltantes);
            borrador = Map.copyOf(borrador);
        }

        @Override
        public TipoRespuesta tipo() {
            return TipoRespuesta.PREGUNTA;
        }

        @Override
        public RespuestaAgente transformarTextos(UnaryOperator<String> transformacion) {
            List<Faltante> nuevos = faltantes.stream()
                    .map(f -> new Faltante(f.campo(), transformacion.apply(f.pregunta()), f.opciones()))
                    .toList();
            return new Pregunta(transformacion.apply(texto), nuevos, borrador);
        }
    }

    /** Una accion de escritura espera la confirmacion del usuario. Nada se ha ejecutado. */
    record Confirmacion(String texto, AccionPropuesta accion) implements RespuestaAgente {

        public Confirmacion {
            Objects.requireNonNull(texto, "texto");
            Objects.requireNonNull(accion, "accion");
        }

        @Override
        public TipoRespuesta tipo() {
            return TipoRespuesta.CONFIRMACION;
        }

        @Override
        public RespuestaAgente transformarTextos(UnaryOperator<String> transformacion) {
            return new Confirmacion(transformacion.apply(texto), accion);
        }
    }

    /** Respuesta con acciones de UI para el front (se completa en la fase de UI). */
    record Ui(String texto, List<AccionUi> acciones) implements RespuestaAgente {

        public Ui {
            Objects.requireNonNull(texto, "texto");
            acciones = List.copyOf(acciones);
        }

        @Override
        public TipoRespuesta tipo() {
            return TipoRespuesta.UI;
        }

        @Override
        public RespuestaAgente transformarTextos(UnaryOperator<String> transformacion) {
            return new Ui(transformacion.apply(texto), acciones);
        }
    }

    /** Filas de datos con su texto. Las columnas y filas ya vienen filtradas de datos sensibles. */
    record Datos(String texto, List<String> columnas, List<Map<String, Object>> filas) implements RespuestaAgente {

        public Datos {
            Objects.requireNonNull(texto, "texto");
            columnas = List.copyOf(columnas);
            filas = List.copyOf(filas);
        }

        @Override
        public TipoRespuesta tipo() {
            return TipoRespuesta.DATOS;
        }

        @Override
        public RespuestaAgente transformarTextos(UnaryOperator<String> transformacion) {
            return new Datos(transformacion.apply(texto), columnas, filas);
        }
    }

    /** El mensaje se ha bloqueado por seguridad. El texto es fijo y no revela nada. */
    record Bloqueado(String texto) implements RespuestaAgente {

        public Bloqueado {
            Objects.requireNonNull(texto, "texto");
        }

        @Override
        public TipoRespuesta tipo() {
            return TipoRespuesta.BLOQUEADO;
        }

        @Override
        public RespuestaAgente transformarTextos(UnaryOperator<String> transformacion) {
            return new Bloqueado(transformacion.apply(texto));
        }
    }

    /** La intencion pide una accion que el usuario no puede hacer desde el agente. */
    record SinPermiso(String texto) implements RespuestaAgente {

        public SinPermiso {
            Objects.requireNonNull(texto, "texto");
        }

        @Override
        public TipoRespuesta tipo() {
            return TipoRespuesta.SIN_PERMISO;
        }

        @Override
        public RespuestaAgente transformarTextos(UnaryOperator<String> transformacion) {
            return new SinPermiso(transformacion.apply(texto));
        }
    }
}
