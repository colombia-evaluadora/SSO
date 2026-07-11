package com.co.eurekatic.ssoadmin.provisioner;

/**
 * Raised by the provisioner chain when a row in the QUERY
 * lifecycle can't proceed. The {@link Code} drives the HTTP
 * status the controller layer returns:
 *
 * <ul>
 *   <li>{@link Code#CONTAINER_CREATE_FAILED} → 502 Bad Gateway</li>
 *   <li>{@link Code#EUREKA_TIMEOUT}         → 504 Gateway Timeout</li>
 *   <li>{@link Code#SIDECAR_UNREACHABLE}    → 503 Service Unavailable</li>
 *   <li>{@link Code#INVALID_SPEC}           → 400 Bad Request</li>
 * </ul>
 */
public class ProvisioningException extends RuntimeException {

    public enum Code {
        CONTAINER_CREATE_FAILED,
        EUREKA_TIMEOUT,
        SIDECAR_UNREACHABLE,
        INVALID_SPEC
    }

    private final Code code;

    public ProvisioningException(Code code, String message) {
        super(message);
        this.code = code;
    }

    public ProvisioningException(Code code, String message, Throwable cause) {
        super(message, cause);
        this.code = code;
    }

    public Code getCode() {
        return code;
    }
}