package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import com.co.eurekatic.aicontrol.agente.catalogo.esquema.NombresParametro;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;

/**
 * Regla de ids: un argumento que es identificador solo vale si salio de un resultado previo de
 * la conversacion, o si el usuario lo escribio literalmente en su ultimo mensaje (un año o un
 * numero de documento que el propio usuario dio). Asi el modelo no adivina pks.
 */
@Component
public class VerificadorIds {

    private final RegistroIds registro;

    public VerificadorIds(RegistroIds registro) {
        this.registro = registro;
    }

    /**
     * @return un error por cada parametro de identificador que no se pudo justificar; vacio si todos valen
     */
    public List<String> verificar(HerramientaDef herramienta, ArgumentosCanonicos argumentos,
                                  String conversationId, String textoUsuario) {
        NombresParametro nombres = NombresParametro.de(herramienta.parametros());
        String texto = textoUsuario == null ? "" : textoUsuario;
        List<String> errores = new ArrayList<>();
        for (ParametroDef parametro : herramienta.parametros()) {
            Object valor = argumentos.planos().get(parametro.clave());
            if (valor == null || !parametro.esIdentificador()) {
                continue;
            }
            boolean justificado = elementos(valor).stream().allMatch(elemento -> {
                String id = ExtractorIds.textoDe(elemento);
                return id != null && (estaEnTexto(texto, id) || registro.contiene(conversationId, id));
            });
            if (!justificado) {
                errores.add(mensaje(parametro, nombres.nombreModelo(parametro.clave())));
            }
        }
        return List.copyOf(errores);
    }

    private static List<?> elementos(Object valor) {
        return valor instanceof List<?> lista ? lista : List.of(valor);
    }

    /** El id aparece como numero aislado, no como parte de otro numero. */
    static boolean estaEnTexto(String texto, String id) {
        Pattern numeroAislado = Pattern.compile("(?<![\\p{L}\\d])" + Pattern.quote(id) + "(?![\\p{L}\\d])");
        return numeroAislado.matcher(texto).find();
    }

    private static String mensaje(ParametroDef parametro, String nombre) {
        String pista = parametro.resuelveCon()
                .map(herramienta -> " Obtenlo con " + herramienta + " y usa el id que devuelva.")
                .orElse(" Obtenlo de una consulta previa de esta conversacion.");
        return "El valor de '" + nombre + "' es un identificador que no aparece en ningun resultado previo." + pista;
    }
}
