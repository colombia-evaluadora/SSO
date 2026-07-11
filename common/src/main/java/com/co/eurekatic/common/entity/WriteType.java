package com.co.eurekatic.common.entity;

/**
 * The two flavors of write the catalog supports. Stored as a
 * VARCHAR in {@code WRITE_DEFINITION.WRITE_TYPE} (see
 * {@link WriteDefinition}) — never as a Java enum ordinal, so a
 * schema change does not silently renumber an existing row.
 *
 * <p>Adding a new value here is a breaking change for
 * {@code query-service}'s {@code WriteService.doInsert/doUpdate}
 * switch; do it deliberately, with a feature flag and a test.
 */
public enum WriteType {
    INSERT,
    UPDATE
}
