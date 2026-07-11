package com.co.eurekatic.auth.web;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * Endpoints that are part of the legacy API surface but are stubbed in
 * the modernized version. Each returns 501 with a JSON body explaining
 * what's missing, so clients see a clear signal rather than a 404.
 */
@RestController
public class StubsController {

    /**
     * Google login. The legacy endpoint took a Google id_token and an
     * app_name, verified the id_token with the Google API client, and
     * provisioned / authenticated the user. Modernizing this requires
     * a Google OAuth client configuration and a JWT verifier; deferred.
     */
    @PostMapping("/googleLogin")
    public ResponseEntity<Map<String, String>> googleLogin(@RequestBody(required = false) Map<String, Object> body) {
        return ResponseEntity.status(HttpStatus.NOT_IMPLEMENTED).body(Map.of(
                "error", "google_login_not_configured",
                "message", "Google login is not yet implemented in the modernized auth-center. "
                        + "Use POST /login with email/password instead."
        ));
    }
}
