package com.co.eurekatic.comms.actividades;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

/**
 * Lectura del modelo academico ({@code academico_test}) para saber a quien
 * llega cada actividad: el establecimiento del usuario, su poblacion
 * (estudiantes con matricula Cursando, sus acudientes y los funcionarios de
 * TSEDE_USUARIO + rector/secretaria) y los cursos y cargos que el front ofrece
 * como grupos de votantes. Todas las personas se devuelven como
 * {@code public.users.id_user}; quien no tiene cuenta en el SSO no aparece.
 */
@Repository
public class DirectorioEscolar {

    /** Matricula activa (ESTADO_MATRICULA VALOR '1' = Cursando, V166). */
    private static final String MATRICULAS = """
             FROM academico_test.TMATRICULA m
            JOIN academico_test.TLISTA_VALOR em ON em.PK_LISTA_VALOR = m.FK_TLV_ESTADO_MATRICULA
                 AND em.CATEGORIA = 'ESTADO_MATRICULA' AND em.VALOR = '1'
            JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE AND es.ACTIVE
            JOIN academico_test.TUSUARIO tu ON tu.PK_TUSUARIO = es.FK_TUSUARIO AND tu.ACTIVE
            JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
            JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
            JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
            JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
            WHERE s.FK_TESTABLECIMIENTO = :est AND m.ACTIVE""";

    /** Funcionarios por sede (cargo = TROL.NOMBRE) y rector/secretaria del EE. */
    private static final String FUNCIONARIOS = """
            SELECT tu.PK_TUSUARIO, tu.CUENTA, tr.NOMBRE AS cargo
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
              JOIN academico_test.TROL tr ON tr.PK_TROL = su.FK_TROL
              JOIN academico_test.TUSUARIO tu ON tu.PK_TUSUARIO = su.FK_TUSUARIO AND tu.ACTIVE
             WHERE s.FK_TESTABLECIMIENTO = :est AND su.ACTIVE
            UNION
            SELECT tu.PK_TUSUARIO, tu.CUENTA,
                   CASE WHEN f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR THEN 'Rector' ELSE 'Secretaria' END
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f
                ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA) AND f.ACTIVE
              JOIN academico_test.TUSUARIO tu ON tu.PK_TUSUARIO = f.FK_TUSUARIO AND tu.ACTIVE
             WHERE e.PK_ESTABLECIMIENTO = :est""";

    private final JdbcClient jdbc;

    public DirectorioEscolar(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    /** Establecimiento del usuario: su sede predeterminada o, si es rector/secretaria, su EE. */
    public Optional<Long> establecimiento(long idUser) {
        return jdbc.sql("""
                WITH u AS (SELECT public.fn_get_academico_usuario_id(:id) AS tu)
                SELECT est FROM (
                    (SELECT s.FK_TESTABLECIMIENTO AS est, 0 AS prioridad
                       FROM academico_test.TSEDE_USUARIO su
                       JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
                      WHERE su.FK_TUSUARIO = (SELECT tu FROM u) AND su.ACTIVE
                      ORDER BY (su.PREDETERMINADO = 1) DESC, su.ORDEN LIMIT 1)
                    UNION ALL
                    (SELECT e.PK_ESTABLECIMIENTO, 1
                       FROM academico_test.TESTABLECIMIENTO e
                       JOIN academico_test.TFUNCIONARIO f
                         ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
                      WHERE f.FK_TUSUARIO = (SELECT tu FROM u) LIMIT 1)
                ) x ORDER BY prioridad LIMIT 1""")
                .param("id", idUser).query(Long.class).optional();
    }

    /** Toda la poblacion del establecimiento: id_user → roles del SSO. */
    public Map<Long, Set<String>> poblacion(long est) {
        Map<Long, Set<String>> out = new LinkedHashMap<>();
        jdbc.sql("""
                WITH ids AS (
                    SELECT pu.id_user
                      FROM (SELECT tu.CORREO_ELECTRONICO AS correo, m.FK_TPADRE """ + MATRICULAS + """
                           ) e
                      JOIN public.users pu ON upper(pu.email) = upper(e.correo)
                    UNION
                    SELECT pu.id_user
                      FROM (SELECT m.FK_TPADRE """ + MATRICULAS + """
                           ) e
                      JOIN academico_test.TPADRE tp ON tp.PK_TPADRE = e.FK_TPADRE
                      JOIN academico_test.TUSUARIO tua ON tua.PK_TUSUARIO = tp.FK_TUSUARIO
                      JOIN public.users pu ON pu.email = tua.CUENTA
                    UNION
                    SELECT pu.id_user FROM (""" + FUNCIONARIOS + """
                           ) f JOIN public.users pu ON pu.email = f.CUENTA
                )
                SELECT u.id_user,
                       COALESCE((SELECT string_agg(r.name, ',') FROM public.role_users ur
                                   JOIN public.role r ON r.id_role = ur.role_id WHERE ur.user_id = u.id_user), '')
                  FROM ids JOIN public.users u ON u.id_user = ids.id_user
                 WHERE u.active AND u.enabled""")
                .param("est", est)
                .query((rs, n) -> out.put(rs.getLong(1),
                        rs.getString(2).isEmpty() ? Set.of() : Set.of(rs.getString(2).split(","))))
                .list();
        return out;
    }

    /** Cursos ("6 A") con estudiantes matriculados y cargos de funcionarios. */
    public List<String> cursos(long est) {
        return jdbc.sql("SELECT DISTINCT g.NOMBRE || ' ' || gr.NOMBRE AS curso " + MATRICULAS + " ORDER BY 1")
                .param("est", est).query(String.class).list();
    }

    public List<String> cargos(long est) {
        return jdbc.sql("SELECT DISTINCT cargo FROM (" + FUNCIONARIOS + ") f ORDER BY 1")
                .param("est", est).query(String.class).list();
    }

    public record Persona(long id, String nombre, String documento) { }

    public List<Persona> estudiantesDeCurso(long est, String curso) {
        return jdbc.sql("""
                SELECT DISTINCT pu.id_user,
                       trim(concat_ws(' ', tu.PRIMER_APELLIDO, tu.SEGUNDO_APELLIDO, tu.PRIMER_NOMBRE, tu.SEGUNDO_NOMBRE)),
                       trim(concat_ws(' ', td.VALOR, tu.IDENTIFICACION))
                """ + MATRICULAS.replace("WHERE s.FK_TESTABLECIMIENTO", """
                LEFT JOIN academico_test.TLISTA_VALOR td ON td.PK_LISTA_VALOR = tu.FK_TLV_TIPO_DOCUMENTO
                JOIN public.users pu ON upper(pu.email) = upper(tu.CORREO_ELECTRONICO) AND pu.active AND pu.enabled
                WHERE s.FK_TESTABLECIMIENTO""") + """
                   AND g.NOMBRE || ' ' || gr.NOMBRE = :curso
                 ORDER BY 2""")
                .param("est", est).param("curso", curso)
                .query((rs, n) -> new Persona(rs.getLong(1), rs.getString(2), rs.getString(3))).list();
    }

    public List<Persona> funcionariosConCargo(long est, String cargo) {
        return jdbc.sql("""
                SELECT DISTINCT pu.id_user,
                       trim(concat_ws(' ', tu.PRIMER_APELLIDO, tu.SEGUNDO_APELLIDO, tu.PRIMER_NOMBRE, tu.SEGUNDO_NOMBRE)),
                       trim(concat_ws(' ', td.VALOR, tu.IDENTIFICACION))
                  FROM (""" + FUNCIONARIOS + """
                       ) f
                  JOIN academico_test.TUSUARIO tu ON tu.PK_TUSUARIO = f.PK_TUSUARIO
                  LEFT JOIN academico_test.TLISTA_VALOR td ON td.PK_LISTA_VALOR = tu.FK_TLV_TIPO_DOCUMENTO
                  JOIN public.users pu ON pu.email = f.CUENTA AND pu.active AND pu.enabled
                 WHERE f.cargo = :cargo
                 ORDER BY 2""")
                .param("est", est).param("cargo", cargo)
                .query((rs, n) -> new Persona(rs.getLong(1), rs.getString(2), rs.getString(3))).list();
    }
}
