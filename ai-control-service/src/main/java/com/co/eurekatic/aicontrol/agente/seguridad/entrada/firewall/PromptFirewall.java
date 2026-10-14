package com.co.eurekatic.aicontrol.agente.seguridad.entrada.firewall;

import com.co.eurekatic.aicontrol.agente.seguridad.Hallazgo;
import com.co.eurekatic.aicontrol.agente.seguridad.Motivo;
import com.co.eurekatic.aicontrol.agente.seguridad.NormalizadorTexto;
import com.co.eurekatic.aicontrol.agente.seguridad.Riesgo;
import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Optional;

/**
 * Primera barrera de la entrada: determinista, sin modelo, antes de cualquier
 * llamada al proveedor. Compone las {@link ReglaFirewall} en orden y toma el
 * riesgo maximo; si una regla da ALTO, no se evaluan las siguientes.
 *
 * <p>Los patrones van sobre el texto plegado porque el advisor de seguridad de
 * Spring AI distingue mayusculas y se le escapan las variantes con tilde o
 * ancho cero.
 */
@Component
public class PromptFirewall {

    static final Motivo VACIO = new Motivo("VACIO");

    private final List<ReglaFirewall> reglas;

    public PromptFirewall(AgenteProperties props) {
        this.reglas = List.of(
                new ReglaFirewall.Longitud(props.limites().textoMaxCaracteres()),
                new ReglaFirewall.Patrones(PatronesInyeccion.INYECCION),
                new ReglaFirewall.Patrones(PatronesInyeccion.CODIFICADOS),
                new ReglaFirewall.MezclaAlfabetos());
    }

    /** Revisa la entrada del usuario. Nunca lanza: una entrada nula es vacia. */
    public ResultadoFirewall revisar(String entrada) {
        String normalizado = NormalizadorTexto.normalizar(entrada == null ? "" : entrada);
        if (normalizado.isEmpty()) {
            return new ResultadoFirewall(false, "", Riesgo.BAJO, Optional.of(VACIO));
        }

        ReglaFirewall.Texto texto = new ReglaFirewall.Texto(normalizado, NormalizadorTexto.plegar(normalizado));
        Optional<Hallazgo> mayor = Optional.empty();
        for (ReglaFirewall regla : reglas) {
            mayor = Hallazgo.mayor(mayor, regla.evaluar(texto));
            if (mayor.isPresent() && mayor.get().riesgo().bloquea()) {
                break;
            }
        }

        Riesgo riesgo = mayor.map(Hallazgo::riesgo).orElse(Riesgo.BAJO);
        return new ResultadoFirewall(!riesgo.bloquea(), normalizado, riesgo, mayor.map(Hallazgo::motivo));
    }
}
