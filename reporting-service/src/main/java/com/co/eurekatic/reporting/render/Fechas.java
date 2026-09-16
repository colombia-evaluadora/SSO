package com.co.eurekatic.reporting.render;

import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.regex.Pattern;

/**
 * Como se imprimen las fechas en los reportes.
 *
 * <p>Existe por dos problemas que se veian en los archivos generados:
 *
 * <ol>
 *   <li>Las fechas salian crudas, tal como viajan en el JSON
 *       ({@code 2026-08-26T00:00:00.000Z}). Nadie lee eso en un PDF: la
 *       fecha de inicio de una unidad es "26/08/2026", sin hora ni Z.</li>
 *   <li>La hora de generacion del documento salia en la zona del JVM, que
 *       en el contenedor es UTC — cinco horas adelantada. Un reporte
 *       exportado a las 3 de la tarde decia "20:00".</li>
 * </ol>
 *
 * <h2>Por que la hora de Colombia es fija y no configurable</h2>
 *
 * El membrete no describe al servidor, describe al usuario: lo unico que
 * significa "generado el ..." es "cuando lo pidio quien lo pidio", y todos
 * los usuarios de este sistema estan en Colombia. Dejarlo en la zona del
 * proceso hace que el dato dependa de donde este desplegado el contenedor,
 * que es justo lo que no debe influir.
 *
 * <h2>La trampa: un DATE no se puede convertir de zona</h2>
 *
 * Esta es la parte delicada y la razon de que {@link #formatear} no se
 * limite a pasar todo por la zona de Bogota.
 *
 * <p>El query-service serializa las columnas DATE de PostgreSQL como un
 * instante a MEDIANOCHE UTC: la fecha {@code 2026-08-26} viaja como
 * {@code 2026-08-26T00:00:00.000Z}. Si eso se convierte a America/Bogota
 * (UTC-5) da {@code 2026-08-25T19:00}, o sea que la unidad que empieza el
 * 26 se imprimiria como que empieza el 25. Un dia entero de corrimiento,
 * en TODAS las fechas de TODOS los reportes, y ademas silencioso: el
 * numero se ve perfectamente plausible.
 *
 * <p>Por eso se distingue:
 *
 * <ul>
 *   <li>Instante a medianoche UTC exacta = columna DATE. Se imprime su
 *       fecha de calendario tal cual, SIN convertir de zona, y sin hora.</li>
 *   <li>Instante con hora real = columna de marca de tiempo (el
 *       {@code ts} de auditoria, por ejemplo). Ahi la hora SI es
 *       informacion, asi que se convierte a la hora de Colombia y se
 *       imprime con ella.</li>
 * </ul>
 *
 * <p>El precio de esa regla es un caso extremo conocido: un evento
 * ocurrido exactamente a las 00:00:00.000 UTC se imprime como fecha sin
 * hora. Se acepta a sabiendas — la alternativa (convertir todo) corre un
 * dia todas las fechas de todos los reportes, que es un error mucho peor
 * y mucho mas frecuente que perder la hora de un evento a medianoche.
 */
public final class Fechas {

    private Fechas() {}

    /** Zona de los usuarios del sistema. Ver el javadoc de la clase. */
    public static final ZoneId COLOMBIA = ZoneId.of("America/Bogota");

    static final DateTimeFormatter SOLO_FECHA = DateTimeFormatter.ofPattern("dd/MM/yyyy");

    /**
     * Reloj de 12 horas con AM/PM, que es como se lee la hora en Colombia.
     *
     * <p>El {@code Locale.US} NO es un descuido ni un copiar y pegar: fija
     * el texto del marcador en "AM"/"PM". Sin el se usaria el locale del
     * proceso, y con el locale espanol las versiones recientes de CLDR
     * escriben "a. m."/"p. m." — con puntos y espacio intercalado. O sea
     * que el mismo reporte diria una cosa u otra segun como este arrancado
     * el contenedor, que es el mismo problema que la zona horaria: un dato
     * del documento no puede depender de donde corre el proceso.
     */
    static final DateTimeFormatter FECHA_Y_HORA =
            DateTimeFormatter.ofPattern("dd/MM/yyyy hh:mm a", java.util.Locale.US);

    /**
     * Texto ISO-8601 con fecha y, opcionalmente, hora y desfase. Se exige
     * que calce ENTERO para no reescribir una cadena que solo empiece
     * pareciendose a una fecha.
     */
    private static final Pattern ISO = Pattern.compile(
            "\\d{4}-\\d{2}-\\d{2}"
            + "(?:[T ]\\d{2}:\\d{2}(?::\\d{2}(?:\\.\\d{1,9})?)?)?"
            + "(?:Z|[+-]\\d{2}:?\\d{2})?");

    /** Ahora, en hora de Colombia. */
    public static ZonedDateTime ahora() {
        return ZonedDateTime.now(COLOMBIA);
    }

    /**
     * Da el texto a imprimir para una fecha que llego como cadena, o
     * {@code null} si el valor no es una fecha — en cuyo caso el llamante
     * debe dejarlo tal cual.
     *
     * <p>Devolver null en vez de lanzar es deliberado: por aca pasan TODOS
     * los valores de texto de todos los reportes, y la inmensa mayoria no
     * son fechas. "No es una fecha" es el caso normal, no un error.
     */
    static String formatear(String crudo) {
        if (crudo == null) {
            return null;
        }
        String v = crudo.trim();
        if (v.length() < 10 || !ISO.matcher(v).matches()) {
            return null;
        }
        try {
            // Solo fecha, sin hora: no hay nada que decidir.
            if (v.length() == 10) {
                return LocalDate.parse(v).format(SOLO_FECHA);
            }

            String norm = v.replace(' ', 'T');

            // Con desfase explicito (…Z o …-05:00) es un INSTANTE.
            if (norm.endsWith("Z") || norm.matches(".*[+-]\\d{2}:?\\d{2}$")) {
                Instant instante = OffsetDateTime.parse(norm).toInstant();
                OffsetDateTime enUtc = instante.atOffset(ZoneOffset.UTC);
                if (LocalTime.MIDNIGHT.equals(enUtc.toLocalTime())) {
                    // DATE disfrazado de instante: su fecha se imprime tal
                    // cual. Convertirlo restaria un dia (ver el javadoc).
                    return enUtc.toLocalDate().format(SOLO_FECHA);
                }
                return instante.atZone(COLOMBIA).format(FECHA_Y_HORA);
            }

            // Sin desfase no hay de que convertir: ya viene en hora local.
            LocalDateTime local = LocalDateTime.parse(norm);
            return LocalTime.MIDNIGHT.equals(local.toLocalTime())
                    ? local.toLocalDate().format(SOLO_FECHA)
                    : local.format(FECHA_Y_HORA);

        } catch (DateTimeParseException e) {
            // Calzo el patron pero no es una fecha valida (un 2026-02-31).
            // Se devuelve tal cual antes que inventar un valor.
            return null;
        }
    }
}
