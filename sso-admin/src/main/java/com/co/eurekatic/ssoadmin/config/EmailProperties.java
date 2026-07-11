package com.co.eurekatic.ssoadmin.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Email-related properties for sso-admin's activation and
 * restore-password flows. Bound from {@code sso.email.*} in
 * {@code application.yml}.
 *
 * <p>The legacy hardcoded Gmail SMTP credentials in
 * {@code application.yml}. That is gone — the actual SMTP
 * connection is configured by Spring Boot's {@code spring.mail.*}
 * properties (env-driven), and this record only carries the
 * branding and URLs that go into the email templates.
 *
 * @param from           "From" address for outgoing emails
 * @param company        Company name rendered in the template header
 * @param appName        App name rendered in the template body
 * @param logoUrl        Logo URL rendered in the template header
 * @param activationUrl  Base URL the activation email link points at
 *                       (the gateway URL, not the sso-admin internal
 *                       URL — the user clicks this from their email
 *                       client)
 * @param restoreUrl     Base URL the restore-password email link points at
 * @param activationTemplate Freemarker template name (loaded from
 *                           {@code classpath:/templates/})
 * @param restoreTemplate    Freemarker template name for restore-password
 */
@ConfigurationProperties(prefix = "sso.email")
public record EmailProperties(
        String from,
        String company,
        String appName,
        String logoUrl,
        String activationUrl,
        String restoreUrl,
        String activationTemplate,
        String restoreTemplate
) {
    /**
     * Default values mirror the legacy {@code general.properties}
     * defaults. Production deployments MUST override {@code from},
     * {@code logoUrl}, and the URLs.
     *
     * <p>Both URLs point at SPA pages under {@code /admin/**} (the
     * admin-ui SPA is served there by the gateway's
     * {@code AdminUiGlobalFilter}). The SPA pages render the
     * password form and POST {@code {token, password}} back to the
     * {@code /sso-admin/activateAccount} and {@code /restorePassword}
     * endpoints. The legacy defaults pointed at the
     * {@code /sso-admin/activateAccount} GET endpoint directly,
     * which would have left the password in the URL query string
     * had the SPA not existed — closed in this branch.
     *
     * <p>The {@code restoreUrl} default used to be a copy-paste of
     * {@code activationUrl} (both pointing at
     * {@code /sso-admin/activateAccount}). That bug was masked by
     * {@code docker-compose.yml}'s env-var override
     * ({@code SSO_RESTORE_URL}) being correct, but it would have
     * surfaced in any deployment that ran {@code sso-admin}
     * outside compose. Fixed here.
     */
    public EmailProperties {
        if (from == null || from.isBlank()) from = "no-reply@example.com";
        if (company == null || company.isBlank()) company = "Example Inc.";
        if (appName == null || appName.isBlank()) appName = "SSO Modernizado";
        if (logoUrl == null || logoUrl.isBlank()) logoUrl = "https://www.example.com/img/logo.png";
        if (activationUrl == null || activationUrl.isBlank()) activationUrl = "http://localhost:8080/admin/activate";
        if (restoreUrl == null || restoreUrl.isBlank()) restoreUrl = "http://localhost:8080/admin/restore-password";
        if (activationTemplate == null || activationTemplate.isBlank()) activationTemplate = "activation-account.html";
        if (restoreTemplate == null || restoreTemplate.isBlank()) restoreTemplate = "restore-password-account.html";
    }
}
