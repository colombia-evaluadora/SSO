package com.co.eurekatic.common.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.ManyToMany;
import jakarta.persistence.Table;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;
import org.springframework.security.core.GrantedAuthority;

import java.util.HashSet;
import java.util.Objects;
import java.util.Set;

/**
 * Role entity. Implements {@link GrantedAuthority} so a User's roles can be
 * returned directly to Spring Security's authentication pipeline.
 *
 * <p>The role's {@code name} IS the authority. Store it as "USER" / "ADMIN"
 * (without the "ROLE_" prefix); use {@code hasAuthority("USER")} in security
 * expressions, or {@code hasRole("USER")} which adds the prefix automatically.
 */
@Entity
@Table(name = "role")
@Getter
@Setter
@NoArgsConstructor
public class Role implements GrantedAuthority {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "id_role")
    private Long id;

    @Column(name = "name", nullable = false, unique = true, length = 64)
    private String name;

    @Column(name = "description", length = 255)
    private String description;

    @ManyToMany(mappedBy = "roles")
    @Setter(AccessLevel.NONE)
    private Set<User> users = new HashSet<>();

    public Role(String name) {
        this.name = name;
    }

    public Role(String name, String description) {
        this.name = name;
        this.description = description;
    }

    /**
     * Spring Security contract: returns the authority string. We return the
     * bare role name so {@code hasAuthority("USER")} works out of the box.
     */
    @Override
    public String getAuthority() {
        return name;
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Role other)) return false;
        return id != null && id.equals(other.id);
    }

    @Override
    public int hashCode() {
        return Objects.hashCode(id);
    }
}
