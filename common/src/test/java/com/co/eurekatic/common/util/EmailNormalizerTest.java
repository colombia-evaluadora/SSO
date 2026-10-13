package com.co.eurekatic.common.util;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class EmailNormalizerTest {

    @Test
    void quitaInvisiblesYEspacios() {
        assertThat(EmailNormalizer.normalize("⁠jorge.sanchez@solinces.com"))
                .isEqualTo("jorge.sanchez@solinces.com");
        assertThat(EmailNormalizer.normalize(" ​a‌@‍x.co﻿  ")).isEqualTo("a@x.co");
    }

    @Test
    void conservaMayusculasYNull() {
        assertThat(EmailNormalizer.normalize("Jorge@Solinces.com")).isEqualTo("Jorge@Solinces.com");
        assertThat(EmailNormalizer.normalize(null)).isNull();
    }
}
