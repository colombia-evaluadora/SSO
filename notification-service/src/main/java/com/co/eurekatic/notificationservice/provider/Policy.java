package com.co.eurekatic.notificationservice.provider;

/**
 * Selection policy applied to the per-channel provider
 * list when the orchestrator iterates them.
 *
 * <ul>
 *   <li>{@link #PRIORITY} — ascending {@code priority} value.
 *       Lower wins. This is the spec default and the most
 *       common production mode.</li>
 *   <li>{@link #WEIGHTED} — used when the operator wants
 *       canarying / load-balancing across N providers with
 *       similar priority. Selection is per-message, weighted
 *       by {@code weight} (uniform random).</li>
 * </ul>
 */
public enum Policy {
    PRIORITY,
    WEIGHTED
}