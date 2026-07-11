package com.co.eurekatic.auth.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.security.web.AuthenticationEntryPoint;
import org.springframework.security.web.access.AccessDeniedHandler;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.time.Instant;
import java.util.Map;

/**
 * 401 / 403 handlers that write a small JSON body instead of letting
 * Spring Security's defaults redirect to a login page or render an
 * HTML error. Used by {@link SecurityConfig}.
 */
@Component
public class JsonAuthHandlers {

    private final ObjectMapper mapper;

    public JsonAuthHandlers(ObjectMapper mapper) {
        this.mapper = mapper;
    }

    public AuthenticationEntryPoint unauthorizedHandler() {
        return (request, response, authException) ->
                write(response, HttpStatus.UNAUTHORIZED, "unauthorized",
                        authException.getMessage());
    }

    public AccessDeniedHandler forbiddenHandler() {
        return (request, response, accessDeniedException) ->
                write(response, HttpStatus.FORBIDDEN, "forbidden",
                        accessDeniedException.getMessage());
    }

    private void write(HttpServletResponse response, HttpStatus status,
                       String error, String message) throws IOException {
        response.setStatus(status.value());
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding("UTF-8");
        mapper.writeValue(response.getOutputStream(), Map.of(
                "timestamp", Instant.now().toString(),
                "status", status.value(),
                "error", error,
                "message", message == null ? "" : message
        ));
    }
}
