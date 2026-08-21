package com.co.eurekatic.common.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;
import jakarta.persistence.UniqueConstraint;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.OffsetDateTime;
import java.util.Objects;

/**
 * V81 — una fila = las restricciones de formato adicionales de UN
 * placeholder de UNA {@link Query}, más allá del tipo/obligatoriedad
 * que ya declara {@code Query.paramTypes}. Ver la migración
 * {@code V81__query_param_constraints.sql} y
 * {@code com.co.eurekatic.common.query.ParamConstraint} (la forma
 * "wire" que el catálogo expone a {@code query-service}).
 *
 * <p>Cascada desde {@link Query#getParamConstraints()}: crear/editar
 * una query reescribe el set completo de filas de esta tabla para
 * esa query (clear + re-add), igual que la sección "Tipos de
 * parámetros" reemplaza {@code PARAM_TYPES} entero en cada guardado.
 */
@Entity
@Table(name = "QUERY_PARAM_CONSTRAINT",
        uniqueConstraints = @UniqueConstraint(columnNames = {"QUERY_ID", "PARAM_KEY"}))
@Getter
@Setter
@NoArgsConstructor
public class QueryParamConstraint {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "ID")
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "QUERY_ID", nullable = false)
    private Query query;

    /** Mismo formato de key que {@code PARAM_TYPES}: {@code "BODY.EDAD"}. */
    @Column(name = "PARAM_KEY", nullable = false, length = 200)
    private String paramKey;

    @Column(name = "ONLY_POSITIVE")
    private Boolean onlyPositive;

    @Column(name = "ALLOW_DECIMALS")
    private Boolean allowDecimals;

    @Column(name = "MAX_DIGITS")
    private Integer maxDigits;

    @Column(name = "NUMERIC_TEXT")
    private Boolean numericText;

    @Column(name = "MIN_LENGTH")
    private Integer minLength;

    @Column(name = "MAX_LENGTH")
    private Integer maxLength;

    @Column(name = "CREATED_DATE", insertable = false, updatable = false)
    private OffsetDateTime createdDate;

    public QueryParamConstraint(Query query, String paramKey,
                                Boolean onlyPositive, Boolean allowDecimals, Integer maxDigits,
                                Boolean numericText, Integer minLength, Integer maxLength) {
        this.query = query;
        this.paramKey = paramKey;
        this.onlyPositive = onlyPositive;
        this.allowDecimals = allowDecimals;
        this.maxDigits = maxDigits;
        this.numericText = numericText;
        this.minLength = minLength;
        this.maxLength = maxLength;
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof QueryParamConstraint other)) return false;
        return id != null && id.equals(other.id);
    }

    @Override
    public int hashCode() {
        return Objects.hashCode(id);
    }
}
