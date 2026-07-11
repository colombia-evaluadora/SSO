package com.co.eurekatic.auth.security;

import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.core.userdetails.UsernameNotFoundException;
import org.springframework.stereotype.Service;

/**
 * Bridges the {@code common} User entity to Spring Security's
 * {@link UserDetailsService} contract. Returns the {@code User} entity
 * directly because it already implements {@code UserDetails} (see
 * {@code common.entity.User}).
 */
@Service
public class AppUserDetailsService implements UserDetailsService {

    private final UserRepository userRepository;

    public AppUserDetailsService(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    @Override
    public UserDetails loadUserByUsername(String email) throws UsernameNotFoundException {
        // The parameter is named "username" only because the
        // UserDetailsService interface mandates that name. We treat
        // it as an email (the unique login identifier since the
        // V12 migration).
        User u = userRepository.findByEmail(email)
                .orElseThrow(() -> new UsernameNotFoundException("User not found: " + email));
        // isEnabled() returns enabled && active. Reject disabled or
        // not-yet-activated accounts here so they cannot log in even if
        // they have a valid password.
        if (!u.isEnabled()) {
            throw new UsernameNotFoundException("User is disabled: " + email);
        }
        return u;
    }
}
