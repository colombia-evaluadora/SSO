package com.co.eurekatic.hello;

import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Mono;

import java.time.Instant;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Hello-world reference controller. Every endpoint reads the
 * {@code X-Authenticated-*} headers that
 * {@code api-gateway}'s {@code UserForwardingGlobalFilter} injects
 * and surfaces them in the response.
 *
 * <p>Trust model: this service assumes the gateway is the trust
 * boundary and the network path between the gateway and this
 * service is locked down. It does NOT re-validate the JWT. This is
 * a deliberate choice for internal services behind a single
 * gateway — for any service exposed directly to the internet, the
 * JWT would need to be re-validated.
 */
@RestController
@RequestMapping("/api")
public class HelloController {

    /**
     * Required by the api-gateway's default-deny rule: any path
     * not on the public allow-list returns 401. The
     * {@code X-Authenticated-User} header is added by the gateway
     * after JWT validation.
     */
    static final String HEADER_USER = "X-Authenticated-User";
    static final String HEADER_ROLES = "X-Authenticated-Roles";
    static final String HEADER_TOKEN_TYPE = "X-Authenticated-Token-Type";

    /**
     * Hello endpoint. Returns a greeting addressed to the calling
     * user. If the gateway didn't inject {@code X-Authenticated-User}
     * (which would be a bug — every request through the gateway
     * gets the header after the JWT filter), the response still
     * succeeds but uses "world" as a stand-in.
     */
    @GetMapping(path = "/hello", produces = MediaType.APPLICATION_JSON_VALUE)
    public Mono<Map<String, Object>> hello(
            @org.springframework.web.bind.annotation.RequestHeader(
                    value = HEADER_USER, required = false) String user,
            @org.springframework.web.bind.annotation.RequestHeader(
                    value = HEADER_ROLES, required = false) String rolesHeader,
            @org.springframework.web.bind.annotation.RequestHeader(
                    value = HEADER_TOKEN_TYPE, required = false) String tokenType) {

        String safeUser = (user == null || user.isBlank()) ? "world" : user;
        List<String> roles = (rolesHeader == null || rolesHeader.isBlank())
                ? List.of()
                : Arrays.stream(rolesHeader.split(","))
                        .map(String::trim)
                        .filter(s -> !s.isEmpty())
                        .toList();

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("message", "Hello, " + safeUser + "!");
        body.put("user", safeUser);
        body.put("roles", roles);
        body.put("tokenType", tokenType);
        body.put("service", "hello-service");
        body.put("timestamp", Instant.now().toString());
        return Mono.just(body);
    }

    /**
     * Diagnostic endpoint. Echoes back every {@code X-Authenticated-*}
     * header so you can confirm the gateway is injecting them as
     * expected.
     */
    @GetMapping(path = "/whoami", produces = MediaType.APPLICATION_JSON_VALUE)
    public Mono<Map<String, Object>> whoami(
            @org.springframework.web.bind.annotation.RequestHeader(
                    value = HEADER_USER, required = false) String user,
            @org.springframework.web.bind.annotation.RequestHeader(
                    value = HEADER_ROLES, required = false) String roles,
            @org.springframework.web.bind.annotation.RequestHeader(
                    value = HEADER_TOKEN_TYPE, required = false) String tokenType) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("x-authenticated-user", user);
        body.put("x-authenticated-roles", roles);
        body.put("x-authenticated-token-type", tokenType);
        body.put("service", "hello-service");
        body.put("timestamp", Instant.now().toString());
        return Mono.just(body);
    }
}
