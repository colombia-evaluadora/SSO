package com.co.eurekatic.query.web.query;

import com.co.eurekatic.query.read.QueryService;
import com.co.eurekatic.query.web.QueryRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

/**
 * Public read path: {@code POST /public/service}.
 *
 * <p>Marked {@code permitAll()} in {@code SecurityConfig}
 * so anonymous traffic can reach it (the legacy was the
 * same — public queries are intended for partner
 * integrations that don't carry a token).
 *
 * <p>Authorization is the catalog row's
 * {@code publicEnd} flag. The {@link QueryService} refuses
 * to run a non-public query through this entry point even
 * if the catalog returned it (defense-in-depth: an admin
 * misbinding a sensitive query with publicEnd=false must
 * not have it exposed via {@code /public/service}).
 */
@RestController
public class PublicQueryController {

    private final QueryService service;

    public PublicQueryController(QueryService service) {
        this.service = service;
    }

    @PostMapping("/public/service")
    public List<Map<String, Object>> publicService(@Valid @RequestBody QueryRequest req) {
        return service.execute(req, true);
    }
}