package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.ssoadmin.dto.FileReferenceLocationRequest;
import com.co.eurekatic.ssoadmin.dto.FileReferenceLocationResponse;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import org.springframework.dao.EmptyResultDataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.List;
import java.util.regex.Pattern;

/**
 * V-file-reference-admin — edición asistida de {@code
 * public.file_reference_location} (V143/V147): el registro global
 * que le dice a file-service en qué {@code schema.tabla} vive cada
 * {@code pk_tarchivo}, sin importar cuál sea (ver {@code
 * ArchivoRepository} en file-service). Hasta ahora, reparar una fila
 * huérfana (p. ej. un {@code pk_tarchivo} escrito por una instancia
 * vieja de file-service que aún no tenía este registro) sólo se
 * podía hacer por SQL directo contra el servidor — ver el caso real
 * de {@code pk_tarchivo=490026} que motivó este endpoint.
 *
 * <p>Nada de JPA a propósito, mismo motivo que {@link
 * EnteUsuarioAdminService}: es una tabla de {@code public} sin
 * entidad propia en este módulo, y este puñado de operaciones no
 * justifica crear una.
 */
@Service
public class FileReferenceLocationAdminService {

    /** Mismo charset que exige file-service (ArchivoRepository#IDENTIFICADOR)
     *  y la validación de {@code microservice.file_storage_schema/table}
     *  (fn_validar_tabla_archivo, V143) — se repite aquí porque este es
     *  otro punto de entrada que interpola el valor en un {@code .formatted(...)}. */
    private static final Pattern IDENTIFICADOR = Pattern.compile("[a-zA-Z_][a-zA-Z0-9_]*");

    private final JdbcTemplate jdbc;

    public FileReferenceLocationAdminService(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public FileReferenceLocationResponse find(long pkTarchivo) {
        List<FileReferenceLocationResponse> rows = jdbc.query("""
                SELECT pk_tarchivo, schema_name, table_name, urls3, created_at
                  FROM public.file_reference_location
                 WHERE pk_tarchivo = ?
                """, FileReferenceLocationAdminService::mapRow, pkTarchivo);
        if (rows.isEmpty()) {
            throw new NotFoundException("FileReferenceLocation", pkTarchivo);
        }
        return rows.get(0);
    }

    /**
     * Crea o corrige la ubicación de un {@code pk_tarchivo}.
     * {@code urls3} nunca lo manda el caller — se relee de la fila
     * destino ({@code schema.tabla WHERE pk_tarchivo = ?}) para que
     * el registro global quede siempre reflejando el dato real, y
     * de paso esa lectura sirve como verificación: si la fila no
     * existe ahí, la operación falla con un 400 explicativo en vez
     * de crear una referencia que apunte a la nada.
     */
    @Transactional
    public FileReferenceLocationResponse upsert(long pkTarchivo, FileReferenceLocationRequest req) {
        String schema = validarIdentificador(req.schemaName(), "schema");
        String table = validarIdentificador(req.tableName(), "tabla");

        String urls3;
        try {
            urls3 = jdbc.queryForObject(
                    "SELECT urls3 FROM %s.%s WHERE pk_tarchivo = ?".formatted(schema, table),
                    String.class, pkTarchivo);
        } catch (EmptyResultDataAccessException e) {
            throw new IllegalArgumentException(
                    "No existe ninguna fila con pk_tarchivo=" + pkTarchivo + " en " + schema + "." + table
                            + " -- la referencia sólo puede apuntar a un archivo que ya exista en esa tabla.");
        }

        jdbc.update("""
                INSERT INTO public.file_reference_location (pk_tarchivo, schema_name, table_name, urls3)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (pk_tarchivo) DO UPDATE
                   SET schema_name = EXCLUDED.schema_name,
                       table_name = EXCLUDED.table_name,
                       urls3 = EXCLUDED.urls3
                """, pkTarchivo, schema, table, urls3);

        return find(pkTarchivo);
    }

    private static String validarIdentificador(String valor, String queEs) {
        if (valor == null || !IDENTIFICADOR.matcher(valor).matches()) {
            throw new IllegalArgumentException(
                    queEs + " '" + valor + "' no es un identificador SQL válido");
        }
        return valor;
    }

    private static FileReferenceLocationResponse mapRow(ResultSet rs, int n) throws SQLException {
        return new FileReferenceLocationResponse(
                rs.getLong("pk_tarchivo"),
                rs.getString("schema_name"),
                rs.getString("table_name"),
                rs.getString("urls3"),
                rs.getTimestamp("created_at").toInstant());
    }
}
