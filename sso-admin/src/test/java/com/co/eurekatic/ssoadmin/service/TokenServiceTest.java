package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.ssoadmin.exception.TokenNotFoundException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class TokenServiceTest {

    @Mock UserRepository userRepository;

    @Test
    void issueActivationTokenStores36CharUuidOnUser() {
        TokenService svc = new TokenService(userRepository);
        User u = new User();

        String token = svc.issueActivationToken(u);

        // RFC 4122 UUID: 36 chars including 4 hyphens.
        assertThat(token).hasSize(36).matches("^[0-9a-f-]{36}$");
        assertThat(u.getTokenActivation()).isEqualTo(token);
    }

    @Test
    void issueRestoreTokenStores36CharUuidOnUser() {
        TokenService svc = new TokenService(userRepository);
        User u = new User();

        String token = svc.issueRestoreToken(u);

        assertThat(token).hasSize(36);
        assertThat(u.getTokenRestore()).isEqualTo(token);
    }

    @Test
    void consumeActivationTokenClearsColumnAndReturnsUser() {
        TokenService svc = new TokenService(userRepository);
        User u = new User();
        u.setTokenActivation("tok");
        u.setTokenActivationExpiresAt(Instant.now().plus(1, ChronoUnit.HOURS));

        when(userRepository.findByTokenActivation("tok")).thenReturn(Optional.of(u));

        User result = svc.consumeActivationToken("tok");

        assertThat(result).isSameAs(u);
        assertThat(u.getTokenActivation()).isNull();
    }

    @Test
    void consumeActivationTokenThrowsWhenNoMatch() {
        TokenService svc = new TokenService(userRepository);
        when(userRepository.findByTokenActivation("ghost")).thenReturn(Optional.empty());

        assertThatThrownBy(() -> svc.consumeActivationToken("ghost"))
                .isInstanceOf(TokenNotFoundException.class);
    }

    @Test
    void consumeRestoreTokenClearsColumnAndReturnsUser() {
        TokenService svc = new TokenService(userRepository);
        User u = new User();
        u.setTokenRestore("rtok");
        u.setTokenRestoreExpiresAt(Instant.now().plus(1, ChronoUnit.HOURS));

        when(userRepository.findByTokenRestore("rtok")).thenReturn(Optional.of(u));

        User result = svc.consumeRestoreToken("rtok");

        assertThat(result).isSameAs(u);
        assertThat(u.getTokenRestore()).isNull();
    }
}
