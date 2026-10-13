package com.co.eurekatic.aicontrol.agente.seguridad;

import org.springframework.stereotype.Component;

/**
 * Entrada completa: firewall determinista y, si no bloquea, clasificador.
 *
 * <p>Un ALTO del firewall no llama al modelo. Si no, el riesgo final es el
 * maximo de los dos. No registra eventos: quien llama decide con
 * {@link EventoSeguridadService} segun la {@link Evaluacion} que recibe.
 */
@Component
public class EvaluadorEntrada {

    private final PromptFirewall firewall;
    private final ClasificadorInyeccion clasificador;

    public EvaluadorEntrada(PromptFirewall firewall, ClasificadorInyeccion clasificador) {
        this.firewall = firewall;
        this.clasificador = clasificador;
    }

    public Evaluacion evaluar(String texto) {
        ResultadoFirewall fw = firewall.revisar(texto);
        if (!fw.permitido() || fw.riesgo() == Riesgo.ALTO) {
            return new Evaluacion(false, fw.riesgo(), fw.motivo(), capaSi(fw.riesgo()), fw.textoNormalizado());
        }

        Clasificacion c = clasificador.clasificar(fw.textoNormalizado());
        Riesgo total = fw.riesgo().max(c.riesgo());
        // Empate: manda el firewall, que es el que se puede explicar sin modelo.
        boolean gana = total == fw.riesgo();
        String motivo = gana ? fw.motivo() : c.motivo();
        CapaSeguridad capa = total == Riesgo.BAJO ? null
                : gana ? CapaSeguridad.FIREWALL : CapaSeguridad.CLASIFICADOR;
        return new Evaluacion(total != Riesgo.ALTO, total, total == Riesgo.BAJO ? null : motivo, capa,
                fw.textoNormalizado());
    }

    private static CapaSeguridad capaSi(Riesgo riesgo) {
        return riesgo == Riesgo.BAJO ? null : CapaSeguridad.FIREWALL;
    }
}
