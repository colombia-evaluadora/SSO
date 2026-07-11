package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.repository.AppRepository;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.stereotype.Service;

import java.util.List;

/**
 * Answers "does role X have a {@code role_app} binding to app Y?",
 * cached in Redis (see {@code CacheConfig}) so
 * {@code SsoAdminAccessManager} doesn't hit Postgres on every
 * request.
 *
 * <p>Cached per role name (not per caller's full role set) — role
 * count is tiny (ADMIN, USER, ...) compared to user count, so this
 * gets a very high hit rate. {@code AppService.bindRole}/{@code
 * unbindRole} evict the exact entry immediately on write; the TTL
 * in {@code CacheConfig} is only a safety net for out-of-band DB
 * edits.
 */
@Service
public class AppAccessService {

    private final AppRepository appRepository;

    public AppAccessService(AppRepository appRepository) {
        this.appRepository = appRepository;
    }

    @Cacheable(value = "app-access", key = "#appName + ':' + #roleName")
    public boolean hasAccess(String appName, String roleName) {
        return appRepository.hasAnyRoleAccess(appName, List.of(roleName));
    }
}
