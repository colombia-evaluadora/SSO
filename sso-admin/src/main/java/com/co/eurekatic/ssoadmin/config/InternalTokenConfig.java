package com.co.eurekatic.ssoadmin.config;

import com.co.eurekatic.ssoadmin.security.InternalTokenFilter;
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
 * <p>The fix: don't {@code @Component} the filter; let
 * THIS config register it as a {@link FilterRegistrationBean}
 * with an explicit order. We pick
 * {@link Ordered#HIGHEST_PRECEDENCE} so an invalid
 * {@code X-Internal-Token} on {@code /internal/**} is
 * rejected BEFORE the JWT auth filter runs (no wasted
 * HMAC + DB hit on a request we already know is bogus)
 * and BEFORE the rest of the security chain (no auth
 * context pollution from a request that should be 401).
 */
@Configuration
public class InternalTokenConfig {

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
