package com.co.eurekatic.query.web.write;

import com.co.eurekatic.query.resilience.QueryResilience;
import com.co.eurekatic.query.write.WriteService;
import com.co.eurekatic.query.web.WriteRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * {@code POST /write}. Authenticated callers only (Spring
 * Security rule). The body carries a uuid and a column→
 * value map.
 *
 * <p>The catalog's per-row role check is the authorization
 * gate; this controller does not add a second one. We
 * intentionally do NOT express "must have ADMIN" or "must
 * have WRITE" at the URL pattern — a non-admin role might
 * legitimately have a write definition bound to it.
 *
 * <p>Rate limited on the same per-principal bucket as the read paths:
 * a write costs the database more than a read, so exempting it was
 * backwards.
 */
@RestController
public class WriteController {

    private final WriteService service;
    private final QueryResilience resilience;

    public WriteController(WriteService service, QueryResilience resilience) {
        this.service = service;
        this.resilience = resilience;
    }

    @PostMapping("/write")
    public Map<String, Object> write(@Valid @RequestBody WriteRequest req) {
        resilience.enforceRateLimit();
        int rows = service.execute(req);
        return Map.of(
                "uuid", req.uuid(),
                "rowsAffected", rows);
    }
}