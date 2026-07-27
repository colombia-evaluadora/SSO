package com.co.eurekatic.common.security;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.JwtException;
import io.jsonwebtoken.Jws;
import io.jsonwebtoken.Jwts;

import java.security.KeyFactory;
import java.security.NoSuchAlgorithmException;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.spec.InvalidKeySpecException;
import java.security.spec.PKCS8EncodedKeySpec;
import java.security.spec.X509EncodedKeySpec;
import java.time.Instant;
import java.util.Base64;
import java.util.Date;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * Stateless JWT issuer + parser. Used by:
 * <ul>
 *   <li>{@code auth-center} to mint access tokens at login</li>
 *   <li>{@code api-gateway}, {@code sso-admin} and
 *       {@code query-service} to validate Bearer tokens</li>
 * </ul>
 *
 * <p><b>RS256.</b> Signing uses the RSA private key from
 * {@link JwtProperties#privateKey()}; verification uses the public
 * key from {@link JwtProperties#publicKey()}. A service configured
 * without a private key can still verify every token but cannot
 * mint one — {@link #issueAccessToken} throws instead of silently
 * producing something. That split is the point of the migration
 * off HS256, where one shared secret gave every service the power
 * to forge tokens for every other.
 *
 * <p>Keys are decoded once in the constructor. A malformed or
 * missing PEM fails at startup, not on the first login — a JWT
 * misconfiguration that only surfaces under traffic is a bad
 * trade for a service that is on the critical path of every
 * request.
 */
public class JwtTokenService {

    private static final String CLAIM_ROLES = "roles";
    private static final String CLAIM_TOKEN_TYPE = "typ";

    private final JwtProperties props;
    private final PublicKey publicKey;
    /** Null on verifier-only services. Guarded by {@link #requirePrivateKey()}. */
    private final PrivateKey privateKey;

    public JwtTokenService(JwtProperties props) {
        this.props = props;
        this.publicKey = readPublicKey(props.publicKey());
        this.privateKey = props.canIssue() ? readPrivateKey(props.privateKey()) : null;
    }

    /* ====================== key loading ====================== */

    /**
     * Strips the PEM armor and whitespace, leaving the base64 body.
     * Accepts the key with literal newlines (a mounted file) or with
     * {@code \n} escapes collapsed into spaces — which is what
     * happens when a multi-line PEM travels through a
     * docker-compose env var, and is the single most common way to
     * get an "InvalidKeySpec" that looks like a corrupt key but is
     * really just formatting.
     */
    private static byte[] decodePem(String pem, String kind) {
        if (pem == null || pem.isBlank()) {
            throw new IllegalStateException(
                    "sso.jwt." + kind + " no está configurada. Genera el par de claves con "
                            + "scripts/gen-jwt-keys.sh y expórtalo en el entorno.");
        }
        String body = pem
                .replaceAll("-----BEGIN [A-Z ]+-----", "")
                .replaceAll("-----END [A-Z ]+-----", "")
                // Un PEM que viaja por .env -> docker-compose -> variable de
                // entorno puede llegar con los saltos como la secuencia
                // literal \n (barra invertida + n) en vez de como salto real,
                // segun quien haya interpretado el escape por el camino. El
                // alfabeto base64 no incluye la barra invertida, asi que
                // quitarla nunca puede corromper una clave valida.
                .replace("\\n", "")
                .replaceAll("\\s", "");
        try {
            return Base64.getDecoder().decode(body);
        } catch (IllegalArgumentException e) {
            throw new IllegalStateException(
                    "sso.jwt." + kind + " no es un PEM válido (el cuerpo no es base64). "
                            + "Debe incluir la armadura -----BEGIN ...----- completa.", e);
        }
    }

    private static PublicKey readPublicKey(String pem) {
        try {
            return KeyFactory.getInstance("RSA")
                    .generatePublic(new X509EncodedKeySpec(decodePem(pem, "public-key")));
        } catch (NoSuchAlgorithmException | InvalidKeySpecException e) {
            throw new IllegalStateException(
                    "sso.jwt.public-key no es una clave pública RSA en formato X.509/SPKI "
                            + "(-----BEGIN PUBLIC KEY-----).", e);
        }
    }

    private static PrivateKey readPrivateKey(String pem) {
        try {
            return KeyFactory.getInstance("RSA")
                    .generatePrivate(new PKCS8EncodedKeySpec(decodePem(pem, "private-key")));
        } catch (NoSuchAlgorithmException | InvalidKeySpecException e) {
            throw new IllegalStateException(
                    "sso.jwt.private-key no es una clave privada RSA en formato PKCS#8 "
                            + "(-----BEGIN PRIVATE KEY-----). Una clave PKCS#1 "
                            + "(-----BEGIN RSA PRIVATE KEY-----) se convierte con: "
                            + "openssl pkcs8 -topk8 -nocrypt -in vieja.pem -out nueva.pem", e);
        }
    }

    private PrivateKey requirePrivateKey() {
        if (privateKey == null) {
            throw new IllegalStateException(
                    "Este servicio está configurado sólo para verificar tokens: no tiene "
                            + "sso.jwt.private-key. Emitir tokens es responsabilidad de auth-center.");
        }
        return privateKey;
    }

    /* ====================== issue ====================== */

    /**
     * Issue a short-lived access token. The {@code sub} claim carries the
     * user's email (the login identifier since the V12 migration); the
     * {@code roles} claim carries the role names.
     */
    public String issueAccessToken(String email, Set<String> roles) {
        return build(email, roles, "access", props.accessTokenTtlSeconds());
    }

    /**
     * Issue a longer-lived API token. Carries the same claims as the
     * access token but a different {@code typ} so gateways and clients
     * can distinguish them and apply different rate limits / cache TTLs.
     */
    public String issueApiToken(String email, Set<String> roles) {
        return build(email, roles, "api", props.apiTokenTtlSeconds());
    }

    private String build(String email, Set<String> roles, String tokenType, long ttlSeconds) {
        Instant now = Instant.now();
        return Jwts.builder()
                .subject(email)
                .issuer(props.issuer())
                .claim(CLAIM_ROLES, List.copyOf(roles == null ? Set.of() : roles))
                .claim(CLAIM_TOKEN_TYPE, tokenType)
                .issuedAt(Date.from(now))
                .expiration(Date.from(now.plusSeconds(ttlSeconds)))
                .signWith(requirePrivateKey(), Jwts.SIG.RS256)
                .compact();
    }

    /* ====================== parse ====================== */

    /**
     * Parse and verify a compact JWS string. Returns an {@link AuthPrincipal}
     * populated from the standard claims plus {@code roles} and {@code typ}.
     *
     * @throws JwtException if the token is malformed, has an invalid
     *         signature, has expired, or fails any of jjwt's default
     *         validations (issuer match is NOT enforced here — see
     *         {@link #parseAndValidateIssuer}).
     */
    public AuthPrincipal parse(String token) {
        return parseInternal(token, false);
    }

    /**
     * Same as {@link #parse(String)} but additionally verifies that the
     * token's {@code iss} claim matches the configured issuer. Use this
     * variant on the api-gateway filter to make sure tokens minted by a
     * foreign system can't be replayed against us.
     */
    public AuthPrincipal parseAndValidateIssuer(String token) {
        return parseInternal(token, true);
    }

    private AuthPrincipal parseInternal(String token, boolean requireIssuerMatch) {
        if (token == null || token.isBlank()) {
            throw new JwtException("Token vacío");
        }
        // verifyWith(publicKey) also pins the algorithm family: a token
        // whose header says alg=none or alg=HS256 is rejected by jjwt
        // rather than verified against the public key as an HMAC secret,
        // which is the classic RS256-to-HS256 confusion attack.
        var parserBuilder = Jwts.parser().verifyWith(publicKey);
        if (requireIssuerMatch) {
            parserBuilder.requireIssuer(props.issuer());
        }
        Jws<Claims> jws = parserBuilder.build().parseSignedClaims(token);
        Claims claims = jws.getPayload();

        Set<String> roles = new LinkedHashSet<>();
        Object rawRoles = claims.get(CLAIM_ROLES);
        if (rawRoles instanceof List<?> list) {
            for (Object r : list) {
                if (r != null) {
                    roles.add(r.toString());
                }
            }
        } else if (rawRoles instanceof String s) {
            // tolerate a single-role token where the claim is a bare string
            roles.add(s);
        }

        String tokenType = claims.get(CLAIM_TOKEN_TYPE, String.class);
        if (tokenType == null) {
            tokenType = "access";
        }

        return new AuthPrincipal(claims.getSubject(), roles, tokenType);
    }
}
