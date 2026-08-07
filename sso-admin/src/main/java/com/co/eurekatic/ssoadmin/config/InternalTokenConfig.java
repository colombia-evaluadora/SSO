package com.co.eurekatic.ssoadmin.config;

import com.co.eurekatic.ssoadmin.security.InternalTokenFilter;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;

/**
 * V30 — explicit {@link FilterRegistrationBean} wiring for
 * {@link InternalTokenFilter}.
 *
 * <p><b>Why not just {@code @Component} on the filter:</b>
 * Spring Boot auto-registers any {@code @Component} that
 * implements {@code jakarta.servlet.Filter} as a global
 * servlet filter at order {@code LOWEST_PRECEDENCE}. When
 * the Spring Security filter chain (which IS ordered)
 * tries to slot our filter in via
 * {@code addFilterBefore(internalTokenFilter,
 * JwtAuthenticationFilter.class)}, the chain builder
 * refuses: it doesn't know the order of our custom
 * anchor (since {@code JwtAuthenticationFilter} is also
 * custom, not a built-in Spring Security filter), and
 * it rejects the whole chain with
 * "Filter class X does not have a registered order".
 *
 * <p>The fix: don't {@code @Component} the filter; this
 * config declares BOTH the filter as a {@code @Bean} and
 * the {@link FilterRegistrationBean} that installs it. The
 * order is {@link Ordered#HIGHEST_PRECEDENCE} so an
 * invalid {@code X-Internal-Token} on {@code /internal/**}
 * is rejected BEFORE the JWT auth filter runs (no wasted
 * HMAC + DB hit on a request we already know is bogus)
 * and BEFORE the rest of the security chain (no auth
 * context pollution from a request that should be 401).
 */
@Configuration
public class InternalTokenConfig {

    /**
     * The filter instance as a Spring bean. Declared
     * here (not as {@code @Component} on the filter
     * class) so Spring Boot doesn't auto-register the
     * filter with order=LOWEST, which conflicted with
     * the Spring Security chain. The
     * {@code @Value} injection still works because the
     * method is invoked by Spring's bean factory, which
     * resolves the placeholder before calling us.
     */
    @Bean
    public InternalTokenFilter internalTokenFilter(
            @Value("${sso.internal.token:change-me-internal-token}") String token) {
        return new InternalTokenFilter(token);
    }

    @Bean
    public FilterRegistrationBean<InternalTokenFilter> internalTokenFilterRegistration(
            InternalTokenFilter filter) {
        FilterRegistrationBean<InternalTokenFilter> reg = new FilterRegistrationBean<>(filter);
        reg.setOrder(Ordered.HIGHEST_PRECEDENCE);
        // Apply to every URL — the filter's own
        // shouldNotFilter() short-circuits when the
        // request URI doesn't start with /internal/.
        reg.addUrlPatterns("/*");
        return reg;
    }
}
