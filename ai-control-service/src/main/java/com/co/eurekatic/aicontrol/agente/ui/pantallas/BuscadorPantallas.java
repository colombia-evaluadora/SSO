package com.co.eurekatic.aicontrol.agente.ui.pantallas;

import com.co.eurekatic.aicontrol.agente.seguridad.NormalizadorTexto;
import com.co.eurekatic.aicontrol.agente.ui.registro.Pantalla;

import java.util.Arrays;
import java.util.Collection;
import java.util.Comparator;
import java.util.List;
import java.util.Set;

/**
 * Busca pantallas por texto sobre nombre, sinonimos, descripcion y menu padre. Puro: recibe solo las
 * pantallas que el usuario ya puede ver, asi que nunca sugiere una sin acceso.
 *
 * <p>Comparacion sin tildes ni mayusculas y con un recorte simple de palabras (las primeras
 * {@value #RAIZ} letras), suficiente para "docentes" / "docente" o "matriculas" / "matricula".
 */
public final class BuscadorPantallas {

    static final int RAIZ = 6;
    private static final int LONGITUD_MINIMA = 3;
    private static final int PESO_NOMBRE = 3;
    private static final int PESO_SINONIMO = 2;
    private static final int PESO_DESCRIPCION = 1;
    private static final int PESO_PADRE = 1;
    private static final Set<String> VACIAS = Set.of(
            "donde", "esta", "estan", "como", "puedo", "quiero", "encuentro", "encontrar", "cambio", "cambiar",
            "para", "pantalla", "seccion", "menu", "opcion", "hago", "hacer", "veo", "ver", "los", "las", "del",
            "una", "uno", "que", "por", "con", "mis", "sus");

    private BuscadorPantallas() {
    }

    /** Las {@code maximo} pantallas mas afines, de mayor a menor; vacio si nada coincide. */
    public static List<Pantalla> buscar(String texto, Collection<Pantalla> visibles, int maximo) {
        List<String> raices = raices(texto);
        if (raices.isEmpty()) {
            return List.of();
        }
        return visibles.stream()
                .map(p -> new Candidata(p, puntuar(p, raices)))
                .filter(c -> c.puntos() > 0)
                .sorted(Comparator.comparingInt(Candidata::puntos).reversed()
                        .thenComparing(c -> c.pantalla().nombre()))
                .limit(maximo)
                .map(Candidata::pantalla)
                .toList();
    }

    static List<String> raices(String texto) {
        return Arrays.stream(NormalizadorTexto.plegar(texto).split("[^\\p{L}\\p{N}]+"))
                .filter(p -> p.length() >= LONGITUD_MINIMA && !VACIAS.contains(p))
                .map(BuscadorPantallas::raiz)
                .distinct()
                .toList();
    }

    private static int puntuar(Pantalla pantalla, List<String> raices) {
        String nombre = NormalizadorTexto.plegar(pantalla.nombre());
        String descripcion = NormalizadorTexto.plegar(pantalla.descripcion());
        String padre = NormalizadorTexto.plegar(pantalla.menuPadre());
        List<String> sinonimos = pantalla.sinonimos().stream().map(NormalizadorTexto::plegar).toList();
        int puntos = 0;
        for (String raiz : raices) {
            puntos += nombre.contains(raiz) ? PESO_NOMBRE : 0;
            puntos += sinonimos.stream().anyMatch(s -> s.contains(raiz)) ? PESO_SINONIMO : 0;
            puntos += descripcion.contains(raiz) ? PESO_DESCRIPCION : 0;
            puntos += padre.contains(raiz) ? PESO_PADRE : 0;
        }
        return puntos;
    }

    private static String raiz(String palabra) {
        return palabra.length() > RAIZ ? palabra.substring(0, RAIZ) : palabra;
    }

    private record Candidata(Pantalla pantalla, int puntos) {
    }
}
