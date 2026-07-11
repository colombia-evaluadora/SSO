package com.co.eurekatic.auth.security;

import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashSet;
import java.util.Set;

/**
 * Computes a user's effective roles for the JWT: their direct roles
 * (role_users) unioned with the roles of every group they belong to
 * (user_group -> group_role). Loaded in one fetch query so no lazy
 * traversal happens outside a session.
 */
@Component
public class EffectiveRolesResolver {

    private final UserRepository userRepository;

    public EffectiveRolesResolver(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    @Transactional(readOnly = true)
    public Set<String> forEmail(String email) {
        Set<String> names = new LinkedHashSet<>();
        userRepository.findByEmailWithEffectiveRoles(email).ifPresent(user -> {
            user.getRoles().forEach(r -> names.add(r.getName()));
            user.getGroups().forEach(g -> g.getRoles().forEach(r -> names.add(r.getName())));
        });
        return names;
    }
}
