package com.co.eurekatic.common.repository;

import com.co.eurekatic.common.entity.User;
import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

import java.util.Optional;

/**
 * Spring Data JPA repository for {@link User}.
 *
 * <p>Methods are derived from the method names; no JPQL / native queries.
 * Add explicit {@code @Query} methods when the derived name would be
 * ambiguous or when you need to join across the {@code role_users} table.
 */
@Repository
public interface UserRepository extends JpaRepository<User, Long> {

    Optional<User> findByEmail(String email);

    /**
     * Igual que {@link #findByEmail} pero con {@code SELECT ... FOR UPDATE}
     * sobre la fila del usuario hasta el fin de la transaccion. Lo usa
     * {@code UserAdminService#forgotPassword}, que reutiliza el token de
     * restauracion vigente: sin el bloqueo, dos pedidos simultaneos de un
     * usuario sin token generarian dos tokens distintos y el ultimo en guardar
     * invalidaria el enlace del primer correo. Bloquea una sola fila y solo
     * durante ese pedido; no lo uses en lecturas comunes.
     */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("SELECT u FROM User u WHERE u.email = :email")
    Optional<User> findByEmailForUpdate(String email);

    Optional<User> findByApiToken(String apiToken);

    Optional<User> findByTokenActivation(String tokenActivation);

    Optional<User> findByTokenRestore(String tokenRestore);

    boolean existsByEmail(String email);

    /**
     * Loads a user with everything needed to compute effective roles in
     * a single round-trip: direct roles, groups, and each group's roles.
     * DISTINCT + Set collections avoid duplicate rows and
     * MultipleBagFetchException. Used only by auth-center's
     * EffectiveRolesResolver at token-issue time.
     */
    @Query("""
           SELECT DISTINCT u FROM User u
           LEFT JOIN FETCH u.roles
           LEFT JOIN FETCH u.groups g
           LEFT JOIN FETCH g.roles
           WHERE u.email = :email
           """)
    Optional<User> findByEmailWithEffectiveRoles(String email);
}
