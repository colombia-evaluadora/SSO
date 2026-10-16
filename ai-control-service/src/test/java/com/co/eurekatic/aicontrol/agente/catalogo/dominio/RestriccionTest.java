package com.co.eurekatic.aicontrol.agente.catalogo.dominio;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class RestriccionTest {

    private static Restriccion conRango(boolean soloPositivos, Optional<BigDecimal> min, Optional<BigDecimal> max,
                                        Optional<Integer> digitos) {
        return new Restriccion(soloPositivos, true, false, min, max, digitos, Optional.empty(), Optional.empty());
    }

    @Test
    void enteroPositivoEmpiezaEnUno() {
        Restriccion r = conRango(true, Optional.empty(), Optional.empty(), Optional.empty());

        assertThat(r.violacion(TipoSql.ENTERO, 0)).isPresent();
        assertThat(r.violacion(TipoSql.ENTERO, 1)).isEmpty();
    }

    @Test
    void numericoPositivoEsEstrictamenteMayorQueCero() {
        Restriccion r = conRango(true, Optional.empty(), Optional.empty(), Optional.empty());

        assertThat(r.violacion(TipoSql.NUMERICO, BigDecimal.ZERO)).isPresent();
        assertThat(r.violacion(TipoSql.NUMERICO, new BigDecimal("0.5"))).isEmpty();
    }

    @Test
    void minimoDeclaradoGanaSiEsMasEstricto() {
        Restriccion r = conRango(true, Optional.of(BigDecimal.valueOf(3)), Optional.empty(), Optional.empty());

        assertThat(r.minimo(TipoSql.ENTERO)).map(Restriccion.Limite::valor).contains(BigDecimal.valueOf(3));
        assertThat(r.violacion(TipoSql.ENTERO, 2)).isPresent();
    }

    @Test
    void maxDigitosLimitaElMayorValorAdmitido() {
        Restriccion r = conRango(false, Optional.empty(), Optional.empty(), Optional.of(1));

        assertThat(r.violacion(TipoSql.ENTERO, 9)).isEmpty();
        assertThat(r.violacion(TipoSql.ENTERO, 10)).isPresent();
    }

    @Test
    void sinDecimalesRechazaFraccionesYAceptaEnterosConCeros() {
        Restriccion r = new Restriccion(false, false, false,
                Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty());

        assertThat(r.violacion(TipoSql.NUMERICO, new BigDecimal("2.5"))).isPresent();
        assertThat(r.violacion(TipoSql.NUMERICO, new BigDecimal("2.00"))).isEmpty();
    }

    @Test
    void longitudYTextoNumericoSobreStrings() {
        Restriccion r = new Restriccion(false, true, true,
                Optional.empty(), Optional.empty(), Optional.empty(), Optional.of(2), Optional.of(4));

        assertThat(r.violacion(TipoSql.TEXTO, "1")).isPresent();
        assertThat(r.violacion(TipoSql.TEXTO, "12345")).isPresent();
        assertThat(r.violacion(TipoSql.TEXTO, "12")).isEmpty();
        assertThat(r.violacion(TipoSql.TEXTO, "1a")).isPresent();
    }

    @Test
    void sinLimitesNoRestringeNada() {
        assertThat(Restriccion.sinLimites().violacion(TipoSql.ENTERO, -5)).isEmpty();
        assertThat(Restriccion.sinLimites().patron()).isEmpty();
    }
}
