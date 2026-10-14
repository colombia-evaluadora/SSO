package com.co.eurekatic.aicontrol.agente.nucleo.respuesta;

import com.fasterxml.jackson.annotation.JsonSubTypes;
import com.fasterxml.jackson.annotation.JsonTypeInfo;

import java.util.Map;
import java.util.Objects;

/**
 * Accion declarativa que el front aplica con su propio codigo (seccion 8 de la propuesta). El conjunto es
 * cerrado y no existe ENVIAR: el envio de un formulario lo hace siempre la persona, con sus validaciones
 * y el gate normales. En JSON cada accion lleva su tipo en {@code op}.
 */
@JsonTypeInfo(use = JsonTypeInfo.Id.NAME, include = JsonTypeInfo.As.PROPERTY, property = "op")
@JsonSubTypes({
        @JsonSubTypes.Type(value = AccionUi.Navegar.class, name = "NAVEGAR"),
        @JsonSubTypes.Type(value = AccionUi.Rellenar.class, name = "RELLENAR"),
        @JsonSubTypes.Type(value = AccionUi.LimpiarCampo.class, name = "LIMPIAR_CAMPO"),
        @JsonSubTypes.Type(value = AccionUi.Resaltar.class, name = "RESALTAR"),
        @JsonSubTypes.Type(value = AccionUi.AbrirPestana.class, name = "ABRIR_PESTANA"),
        @JsonSubTypes.Type(value = AccionUi.AplicarFiltros.class, name = "APLICAR_FILTROS")
})
public sealed interface AccionUi {

    /**
     * Lleva a una pantalla. La URL sale del registro de pantallas, nunca del modelo.
     *
     * @param pantalla codigo de la pantalla en {@code ai.ruta_ui}
     * @param url      ruta del front para esa pantalla
     * @param params   parametros de ruta o de consulta, como texto
     */
    record Navegar(String pantalla, String url, Map<String, String> params) implements AccionUi {
        public Navegar {
            Objects.requireNonNull(pantalla, "pantalla");
            Objects.requireNonNull(url, "url");
            params = Map.copyOf(params);
        }
    }

    /** Asigna valores a campos de un formulario abierto; la persona revisa y envia. */
    record Rellenar(String formulario, Map<String, Object> valores) implements AccionUi {
        public Rellenar {
            Objects.requireNonNull(formulario, "formulario");
            valores = Map.copyOf(valores);
        }
    }

    record LimpiarCampo(String formulario, String campo) implements AccionUi {
        public LimpiarCampo {
            Objects.requireNonNull(formulario, "formulario");
            Objects.requireNonNull(campo, "campo");
        }
    }

    /** Senala un campo, normalmente uno obligatorio que falta. */
    record Resaltar(String formulario, String campo) implements AccionUi {
        public Resaltar {
            Objects.requireNonNull(formulario, "formulario");
            Objects.requireNonNull(campo, "campo");
        }
    }

    record AbrirPestana(String pestana) implements AccionUi {
        public AbrirPestana {
            Objects.requireNonNull(pestana, "pestana");
        }
    }

    /** Filtros de un listado abierto; solo los que la pantalla declara en su contexto. */
    record AplicarFiltros(Map<String, Object> filtros) implements AccionUi {
        public AplicarFiltros {
            filtros = Map.copyOf(filtros);
        }
    }
}
