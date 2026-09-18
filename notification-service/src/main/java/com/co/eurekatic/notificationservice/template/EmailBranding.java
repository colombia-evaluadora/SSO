package com.co.eurekatic.notificationservice.template;

import java.util.Map;

/**
 * Identidad visual de un correo — logo, colores de marca, nombre y
 * correo de soporte — resuelta por {@code appName} (ver {@link
 * com.co.eurekatic.notificationservice.domain.Metadata#appName()}).
 *
 * <p>Vive en código, no en base de datos: a diferencia de {@code
 * provider_config} (que SÍ necesita cambiar sin redeploy — credenciales
 * rotan, cuentas se habilitan/deshabilitan), el branding de una app rara
 * vez cambia y no es sensible — un cambio de logo/color siempre implica
 * tocar el asset o el hex de todos modos, así que un mapa fijo no agrega
 * fricción real.
 *
 * <p>{@code COLOMBIA-EVALUADORA} reproduce EXACTO los valores que ya
 * estaban quemados en {@code password-reset.html} antes de este cambio —
 * un mensaje sin {@code appName} (la mayoría de los flujos hoy) o con un
 * {@code appName} desconocido cae en {@link #DEFAULT}, que es esa misma
 * fila, así que no hay regresión visual para nadie que no sea PIGSE.
 */
public record EmailBranding(
        String orgName,
        /** Nombre de archivo bajo {@code assets/email/}, no una URL — la
         *  URL base (con el SHA fijo) la sigue armando el propio template. */
        String logoFile,
        String supportEmail,
        /** Fondo de la cabecera. */
        String bannerBg,
        /** Color del nombre/alt del logo y del subtítulo cuando Gmail
         *  bloquea las imágenes — tiene que leerse bien sobre {@code
         *  bannerBg}. */
        String bannerFg,
        /** Botón de "Crear nueva contraseña", el paso 3 de la línea de
         *  tiempo y los enlaces de texto — el acento vivo de la marca. */
        String accentColor
) {

    public static final EmailBranding DEFAULT = new EmailBranding(
            "Colombia Evaluadora",
            "logo.png",
            "soporte@colombiaevaluadora.gov.co",
            "#16305c",
            "#ffffff",
            "#1f45e5"
    );

    // PENDIENTE DE CONFIRMAR: soporte@pigse.com es un supuesto razonable
    // (mismo patrón que noreply@pigse.com, el remitente real de
    // smtp-zeptomail-pigse) — nadie lo confirmó como buzón real. Si ese
    // correo no existe, cambiar acá antes de que un usuario de PIGSE le
    // escriba y no le responda nadie.
    private static final EmailBranding PIGSE = new EmailBranding(
            "PIGSE",
            // Variante en blanco del logo (fills recoloreados desde el SVG
            // real de PIGSE) — la original es navy/rojo y se volvía
            // invisible sobre un banner del mismo color.
            "logo-pigse-white.png",
            "soporte@pigse.com",
            "#B33837",
            "#ffffff",
            "#B33837"
    );

    private static final Map<String, EmailBranding> BY_APP_NAME = Map.of(
            "PIGSE", PIGSE
    );

    /** {@code appName} nulo o sin fila propia → {@link #DEFAULT}. */
    public static EmailBranding forAppName(String appName) {
        if (appName == null) return DEFAULT;
        return BY_APP_NAME.getOrDefault(appName.toUpperCase(), DEFAULT);
    }
}
