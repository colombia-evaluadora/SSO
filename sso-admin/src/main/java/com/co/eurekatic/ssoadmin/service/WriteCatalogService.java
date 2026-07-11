package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.WriteDefinition;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.common.repository.WriteDefinitionRepository;
import com.co.eurekatic.ssoadmin.dto.WriteDefinitionDto;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Set;
import java.util.stream.Collectors;

/**
 * Read-side service backing {@code GET /getWrite?uuid=...}.
 *
 * <p>Mirror of {@link QueryCatalogService}, but for the write
 * catalog. The authorization rule is identical (any role in
 * {@link WriteDefinition#getRoles()} is sufficient; no
 * {@code publicEnd} bypass because writes are never public).
 *
 * <p>Why this lives in sso-admin and not query-service: the
 * spec (§3.4) says the catalog is the source of truth for the
 * write-shape definitions, and admin authoring of writes is
 * already in sso-admin. Putting the read endpoint here keeps
 * the entity, the admin CRUD and the consumer-facing read in
 * one module — query-service only needs a RestClient call to
 * {@code /getWrite}.
 */
@Service
public class WriteCatalogService {

    private final WriteDefinitionRepository writeRepo;
    private final UserRepository userRepo;

    public WriteCatalogService(WriteDefinitionRepository writeRepo,
                               UserRepository userRepo) {
        this.writeRepo = writeRepo;
        this.userRepo = userRepo;
    }

    @Transactional(readOnly = true)
    public WriteDefinitionDto resolve(String uuid, String email) {
        WriteDefinition w = writeRepo.findByUuid(uuid)
                .orElseThrow(() -> new AccessDeniedException(
                        "No tiene acceso al write: " + uuid));

        // Writes are never publicEnd — there's no PUBLIC_END
        // column on the legacy write table. So we always go
        // through the role intersection check.
        Set<String> userRoles = userRepo.findByEmail(email)
                .map(u -> u.getRoles().stream()
                        .map(Role::getName)
                        .collect(Collectors.toSet()))
                .orElse(Set.of());
        Set<String> writeRoles = w.getRoles().stream()
                .map(Role::getName)
                .collect(Collectors.toSet());

        boolean authorized = userRoles.stream().anyMatch(writeRoles::contains);
        if (!authorized) {
            throw new AccessDeniedException(
                    "No tiene acceso al write: " + uuid);
        }

        return WriteDefinitionDto.fromEntity(w);
    }
}
