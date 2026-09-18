package com.co.eurekatic.reporting.render;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

class FechasTest {

    @Test
    @DisplayName("un DATE de PostgreSQL NO se corre un dia al imprimirse")
    void dateNoSeCorreUnDia() {
        // Es la razon de ser de esta clase. El query-service serializa las
        // columnas DATE como medianoche UTC; pasarlas por America/Bogota
        // (UTC-5) daria el 25, no el 26. Si este test se cae, TODAS las
        // fechas de TODOS los reportes estan corridas un dia.
        assertEquals("26/08/2026", Fechas.formatear("2026-08-26T00:00:00.000Z"));
        assertEquals("01/01/2026", Fechas.formatear("2026-01-01T00:00:00Z"));
    }

    @Test
    @DisplayName("un DATE se imprime sin hora")
    void dateSinHora() {
        assertEquals("26/08/2026", Fechas.formatear("2026-08-26"));
        assertEquals("31/08/2026", Fechas.formatear("2026-08-31T00:00:00.000Z"));
    }

    @Test
    @DisplayName("una marca de tiempo real se convierte a hora de Colombia")
    void instanteEnHoraDeColombia() {
        // 22:34 UTC son las 17:34 en Bogota, el mismo dia.
        assertEquals("25/08/2026 05:34 PM", Fechas.formatear("2026-08-25T22:34:47.234Z"));
        // Y cruzando la medianoche UTC hacia atras: 02:30Z del 26 son las
        // 21:30 del 25 en Bogota. El dia tambien cambia, y aqui SI debe.
        assertEquals("25/08/2026 09:30 PM", Fechas.formatear("2026-08-26T02:30:00Z"));
    }

    @Test
    @DisplayName("un texto sin desfase se imprime tal como viene, sin convertir")
    void sinDesfaseNoSeConvierte() {
        assertEquals("21/08/2026 11:17 PM", Fechas.formatear("2026-08-21T23:17:18.173"));
        assertEquals("21/08/2026 11:17 PM", Fechas.formatear("2026-08-21 23:17:18"));
    }

    @Test
    @DisplayName("lo que no es una fecha se deja en paz")
    void noFechas() {
        assertNull(Fechas.formatear(null));
        assertNull(Fechas.formatear(""));
        assertNull(Fechas.formatear("SEGUIMIENTO Y VALORACION"));
        assertNull(Fechas.formatear("1234567890"));
        // Empieza como fecha pero no lo es: el patron exige calce completo,
        // para no reescribir a medias un texto que solo la contiene.
        assertNull(Fechas.formatear("2026-08-26 es la fecha"));
        // Calza el patron pero no existe: se deja crudo antes que inventar.
        assertNull(Fechas.formatear("2026-02-31"));
    }

    @Test
    @DisplayName("CellValues aplica el formato, que es como llega a PDF y Excel")
    void cellValuesUsaElFormato() {
        // Los dos renderizadores comparten CellValues justamente para que el
        // mismo dato no se imprima distinto en cada formato.
        assertEquals("26/08/2026", CellValues.toText("2026-08-26T00:00:00.000Z"));
        assertEquals("Centenas", CellValues.toText("Centenas"));
        assertEquals("", CellValues.toText(null));
    }

    @Test
    @DisplayName("la hora va en formato de 12 horas con AM/PM, no de 24")
    void formatoAmPm() {
        // 00:30 UTC del 26 son las 07:30 PM del 25 en Bogota.
        assertEquals("25/08/2026 07:30 PM", Fechas.formatear("2026-08-26T00:30:00Z"));
        // Y una de la manana, que es donde 24h y 12h mas se parecen y mas
        // facil es confundir AM con PM.
        assertEquals("26/08/2026 01:05 AM", Fechas.formatear("2026-08-26T06:05:00Z"));
        // Mediodia y medianoche, los dos casos que rompen los relojes de 12h
        // mal hechos (un 12:00 PM impreso como 00:00 PM).
        assertEquals("26/08/2026 12:00 PM", Fechas.formatear("2026-08-26T17:00:00Z"));
    }

    @Test
    @DisplayName("la hora de generacion sale en zona de Colombia, no en la del JVM")
    void ahoraEnColombia() {
        assertEquals("America/Bogota", Fechas.COLOMBIA.getId());
        // Colombia no tiene horario de verano: siempre UTC-5. Si esto
        // cambiara, el membrete dejaria de ser comparable entre reportes.
        assertEquals(-5 * 3600,
                Fechas.COLOMBIA.getRules().getOffset(java.time.Instant.now()).getTotalSeconds());
    }
}
