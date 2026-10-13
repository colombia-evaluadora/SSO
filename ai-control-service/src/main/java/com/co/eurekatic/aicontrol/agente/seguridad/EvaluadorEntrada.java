package com.co.eurekatic.aicontrol.agente.seguridad;

import org.springframework.stereotype.Component;

import java.util.Optional;

/**
 * Entrada completa: firewall determinista y, si no bloquea, clasificador.
 *
 * <p>Un ALTO del firewall no llama al modelo. Si no, el hallazgo final es el de
 * mayor riesgo de los dos; en empate, el del firewall, que se explica sin modelo.
 * No registra eventos: quien llama decide con {@link EventoSeguridadService}.
 */
@Component
public class EvaluadorEntrada {

    private final PromptFirewall firewall;
    private final ClasificadorRiesgo clasificador;

    public EvaluadorEntrada(PromptFirewall firewall, ClasificadorRiesgo clasificador) {
        this.firewall = firewall;
        this.clasificador = clasificador;
    }

    public Evaluacion evaluar(String texto) {
        ResultadoFirewall fw = firewall.revisar(texto);
        Optional<Hallazgo> delFirewall = hallazgoDelFirewall(fw);
        if (!fw.permitido() || fw.riesgo().bloquea()) {
            return new Evaluacion(false, fw.textoNormalizado(), delFirewall);
        }

        Optional<Hallazgo> mayor = Hallazgo.mayor(delFirewall, clasificador.clasificar(fw.textoNormalizado()));
        boolean permitido = mayor.map(h -> !h.riesgo().bloquea()).orElse(true);
        return new Evaluacion(permitido, fw.textoNormalizado(), mayor);
    }

    /** Un MEDIO o ALTO del firewall como hallazgo; la entrada vacia no lo es. */
    private static Optional<Hallazgo> hallazgoDelFirewall(ResultadoFirewall fw) {
        if (fw.riesgo() == Riesgo.BAJO) {
            return Optional.empty();
        }
        return fw.motivo().map(m -> new Hallazgo(CapaSeguridad.FIREWALL, fw.riesgo(), m));
    }
}
