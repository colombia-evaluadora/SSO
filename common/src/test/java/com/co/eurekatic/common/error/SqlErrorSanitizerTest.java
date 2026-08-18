package com.co.eurekatic.common.error;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.postgresql.util.PSQLException;
import org.postgresql.util.ServerErrorMessage;

import java.sql.SQLException;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Los mensajes usados como fixture están copiados literalmente de
 * {@code postgres/migrations/*.sql} y de la salida real del motor.
 */
class SqlErrorSanitizerTest {

    /**
     * Construye el error tal como llega por el wire protocol: campos separados
     * por NUL, cada uno precedido de su código —{@code C} sqlstate, {@code M}
     * message, {@code D} detail, {@code t} table, {@code n} constraint.
     */
    private static SQLException pg(String sqlState, String message, String detail,
                                   String table, String constraint) {
        StringBuilder wire = new StringBuilder();
        campo(wire, 'S', "ERROR");
        campo(wire, 'C', sqlState);
        campo(wire, 'M', message);
        campo(wire, 'D', detail);
        campo(wire, 't', table);
        campo(wire, 'n', constraint);
        return new PSQLException(new ServerErrorMessage(wire.toString()));
    }

    private static void campo(StringBuilder wire, char codigo, String valor) {
        if (valor != null) {
            wire.append(codigo).append(valor).append('\0');
        }
    }

    /** Un {@code RAISE EXCEPTION} no puebla table ni constraint. */
    private static SQLException raise(String sqlState, String message) {
        return pg(sqlState, message, null, null, null);
    }

    @Nested
    @DisplayName("errores emitidos por el motor")
    class Motor {

        @Test
        void unique_violation_no_filtra_el_valor_que_colisiono() {
            SQLException ex = pg("23505",
                    "duplicate key value violates unique constraint \"ux_tusuario_correo_electronico\"",
                    "Key (correo_electronico)=(juan.perez@colegio.edu.co) already exists.",
                    "tusuario", "ux_tusuario_correo_electronico");

            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(ex);

            assertThat(out.kind()).isEqualTo(SqlErrorKind.DUPLICATE);
            assertThat(out.message())
                    .isEqualTo(SqlErrorKind.DUPLICATE.defaultMessage())
                    .doesNotContain("juan.perez@colegio.edu.co")
                    .doesNotContain("ux_tusuario_correo_electronico")
                    .doesNotContain("tusuario");
        }

        @Test
        void not_null_violation_no_nombra_la_columna() {
            SQLException ex = pg("23502",
                    "null value in column \"correo_electronico\" of relation \"tusuario\" "
                            + "violates not-null constraint",
                    "Failing row contains (1, null).", "tusuario", null);

            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(ex);

            assertThat(out.kind()).isEqualTo(SqlErrorKind.MISSING_REQUIRED);
            assertThat(out.message()).isEqualTo(SqlErrorKind.MISSING_REQUIRED.defaultMessage());
        }

        @Test
        void truncamiento_de_varchar_no_expone_el_tamano_de_columna() {
            // 22001 (string_data_right_truncation): el motor no puebla
            // table/constraint aquí, así que el discriminador de la clase 22
            // es el SQLState, no los campos estructurados. Reproducido en
            // vivo contra Postgres: INSERT con un VARCHAR(130) de 200 chars.
            SQLException ex = raise("22001", "value too long for type character varying(130)");

            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(ex);

            assertThat(out.kind()).isEqualTo(SqlErrorKind.INVALID_VALUE);
            assertThat(out.message())
                    .isEqualTo(SqlErrorKind.INVALID_VALUE.defaultMessage())
                    .doesNotContain("130", "character varying");
        }

        @Test
        void division_por_cero_tampoco_es_mensaje_de_autor() {
            SQLException ex = raise("22012", "division by zero");

            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(ex);

            assertThat(out.message()).isEqualTo(SqlErrorKind.INVALID_VALUE.defaultMessage());
        }

        @Test
        void columna_inexistente_es_interno_y_no_revela_el_identificador() {
            SQLException ex = raise("42703", "column \"fk_testablecimeinto\" does not exist");

            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(ex);

            assertThat(out.kind()).isEqualTo(SqlErrorKind.INTERNAL);
            assertThat(out.message()).isEqualTo(SqlErrorKind.INTERNAL.defaultMessage());
        }

        @Test
        void sin_driver_pg_el_detail_de_la_siguiente_linea_nunca_cruza() {
            SQLException ex = new SQLException(
                    "ERROR: duplicate key value violates unique constraint \"ux_correo\"\n"
                            + "  Detail: Key (correo)=(ana@colegio.edu.co) already exists.",
                    "23505");

            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(ex);

            assertThat(out.message()).doesNotContain("ana@colegio.edu.co", "ux_correo");
        }
    }

    @Nested
    @DisplayName("RAISE EXCEPTION escrito por el autor de la función")
    class Autor {

        @Test
        void ec_22023_es_la_unica_clase_22_que_el_esquema_usa_para_negocio() {
            // Confirmado en vivo contra el catálogo real: crear una sede con
            // un establecimiento inexistente traduce TESTABLECIMIENTO ->
            // "establecimiento" y conserva el resto del texto del autor.
            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(
                    raise("22023", "No existe un TESTABLECIMIENTO activo con PK 999999"));

            assertThat(out.kind()).isEqualTo(SqlErrorKind.INVALID_VALUE);
            assertThat(out.message()).isEqualTo("No existe un establecimiento activo con PK 999999");
        }

        @Test
        void conserva_el_mensaje_de_negocio() {
            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(
                    raise("23503", "El area 12 no existe o esta inactiva"));

            assertThat(out.kind()).isEqualTo(SqlErrorKind.REFERENCE_MISSING);
            assertThat(out.message()).isEqualTo("El area 12 no existe o esta inactiva");
        }

        @Test
        void mismo_sqlstate_que_el_motor_pero_texto_propio() {
            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(
                    raise("23505", "Ya existe un grado con el nombre Quinto en este periodo"));

            assertThat(out.message()).isEqualTo("Ya existe un grado con el nombre Quinto en este periodo");
        }

        @Test
        void traduce_los_nombres_de_tabla_legados() {
            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(
                    raise("P0002", "No existe TESTABLECIMIENTO con PK_ESTABLECIMIENTO = 7"));

            assertThat(out.kind()).isEqualTo(SqlErrorKind.NOT_FOUND);
            assertThat(out.message())
                    .isEqualTo("No existe establecimiento con establecimiento = 7")
                    .doesNotContain("TESTABLECIMIENTO", "PK_");
        }

        @Test
        void traduce_las_columnas_fk_con_prefijo_de_catalogo() {
            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(
                    raise("23503", "FK_TLV_ZONA (4) no existe o no esta activa en TLISTA_VALOR"));

            assertThat(out.message()).isEqualTo("zona (4) no existe o no esta activa en catálogo");
        }

        @Test
        void quita_el_prefijo_con_el_nombre_de_la_funcion() {
            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(
                    raise("P0001", "fn_add_trol: ya existe un TROL activo con codigo=DOC (pk=3)"));

            assertThat(out.kind()).isEqualTo(SqlErrorKind.BUSINESS_RULE);
            assertThat(out.message())
                    .isEqualTo("ya existe un rol activo con codigo=DOC (pk=3)")
                    .doesNotContain("fn_add_trol");
        }

        @Test
        void permiso_denegado_conserva_el_motivo() {
            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(raise("42501",
                    "El usuario no puede gestionar datos academicos de este establecimiento"));

            assertThat(out.kind()).isEqualTo(SqlErrorKind.PERMISSION_DENIED);
            assertThat(out.message())
                    .isEqualTo("El usuario no puede gestionar datos academicos de este establecimiento");
        }

        @Test
        void tabla_fuera_del_diccionario_cae_en_la_red_de_seguridad() {
            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(
                    raise("P0001", "No existe TCONTRATO_NUEVO con ese identificador"));

            assertThat(out.message())
                    .isEqualTo("No existe registro con ese identificador")
                    .doesNotContain("TCONTRATO_NUEVO");
        }

        @Test
        void quita_el_esquema_de_los_identificadores_calificados() {
            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(
                    raise("22023", "valor invalido para academico_test.estado_ai"));

            assertThat(out.kind()).isEqualTo(SqlErrorKind.INVALID_VALUE);
            assertThat(out.message()).isEqualTo("valor invalido para estado_ai");
        }
    }

    @Nested
    class Clasificacion {

        @Test
        void conexion_caida_es_no_disponible_y_no_expone_el_host() {
            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(new SQLException(
                    "Connection to db.interno.local:5432 refused", "08006"));

            assertThat(out.kind()).isEqualTo(SqlErrorKind.UNAVAILABLE);
            assertThat(out.message())
                    .isEqualTo(SqlErrorKind.UNAVAILABLE.defaultMessage())
                    .doesNotContain("db.interno.local");
        }

        @Test
        void recorre_la_cadena_hasta_el_primer_sqlstate_util() {
            SQLException raiz = raise("P0002", "No existe un area activa con PK 9");
            SQLException envoltorio = new SQLException("fallo al ejecutar el batch", (String) null);
            envoltorio.setNextException(raiz);

            SqlErrorSanitizer.Sanitized out = SqlErrorSanitizer.sanitize(envoltorio);

            assertThat(out.kind()).isEqualTo(SqlErrorKind.NOT_FOUND);
            assertThat(out.message()).isEqualTo("No existe un area activa con PK 9");
        }

        @Test
        void sin_sqlstate_reconocible_cae_en_interno() {
            SqlErrorSanitizer.Sanitized out =
                    SqlErrorSanitizer.sanitize(new SQLException("algo pasó"));

            assertThat(out.kind()).isEqualTo(SqlErrorKind.INTERNAL);
            assertThat(out.message()).isEqualTo(SqlErrorKind.INTERNAL.defaultMessage());
        }

        @Test
        void el_codigo_publicado_es_estable() {
            assertThat(SqlErrorSanitizer.sanitize(raise("23503", "x")).code())
                    .isEqualTo("FK_NOT_FOUND");
        }
    }
}
