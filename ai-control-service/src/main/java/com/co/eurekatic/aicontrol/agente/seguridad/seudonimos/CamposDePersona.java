package com.co.eurekatic.aicontrol.agente.seguridad.seudonimos;

import java.util.Locale;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Que columnas de un resultado traen el nombre de una persona. Se compara sin mayusculas ni separadores
 * ({@code PRIMER_NOMBRE}, {@code primerNombre} y {@code primer-nombre} son lo mismo). Un {@code nombre}
 * suelto no cuenta: en el esquema es el de una sede, asignatura o grupo, no el de una persona.
 */
public final class CamposDePersona {

    private static final Pattern SEPARADORES = Pattern.compile("[^a-z0-9]");
    private static final Set<String> NOMBRES_DE_PERSONA = Set.of(
            "estudiante", "nombreestudiante", "docente", "nombredocente", "funcionario", "nombrefuncionario",
            "acudiente", "nombreacudiente", "persona", "nombrepersona", "nombrecompleto", "nombres", "apellidos",
            "primernombre", "segundonombre", "primerapellido", "segundoapellido",
            "firstname", "middlename", "lastname", "secondlastname", "fullname");

    private CamposDePersona() {
    }

    public static boolean esNombreDePersona(String columna) {
        return columna != null
                && NOMBRES_DE_PERSONA.contains(SEPARADORES.matcher(columna.toLowerCase(Locale.ROOT)).replaceAll(""));
    }
}
