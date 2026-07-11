package com.co.eurekatic.query.web.write;

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
 */
@RestController
public class WriteController {

    private final WriteService service;

    public WriteController(WriteService service) {
        this.service = service;
    }

    @PostMapping("/write")
    public Map<String, Object> write(@Valid @RequestBody WriteRequest req) {
        int rows = service.execute(req);
        return Map.of(
                "uuid", req.uuid(),
                "rowsAffected", rows);
    }
}