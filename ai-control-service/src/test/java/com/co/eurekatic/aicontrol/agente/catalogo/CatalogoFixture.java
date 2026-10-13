package com.co.eurekatic.aicontrol.agente.catalogo;

import com.co.eurekatic.aicontrol.agente.catalogo.carga.FilaCatalogo;
import com.co.eurekatic.aicontrol.agente.catalogo.carga.MapeadorHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;

import java.util.List;

/**
 * Filas con la forma exacta que devuelve {@code ai.fn_herramienta_catalogo_interno()}. Los
 * {@code param_types} y los nombres de parametro son los de la base real (V556.2 y los
 * {@code public.query} del servidor local); las descripciones son las de la migracion.
 */
public final class CatalogoFixture {

    private CatalogoFixture() {
    }

    /** PATCH con PARAM.ID y dos campos de persona. {@code BODY.STATUS} y el FILE quedan fuera de la allowlist. */
    public static FilaCatalogo editarFuncionario() {
        return new FilaCatalogo(
                101L,
                "editar_funcionario",
                "ESCRITURA",
                "Edita datos de un funcionario existente. Requiere confirmacion.",
                """
                {"PARAM.ID":{"descripcion":"Pk del funcionario","resuelve_con":"funcionarios_listar","inferible":false},
                 "BODY.PERSON.EMAIL":{"descripcion":"Correo electronico","resuelve_con":null,"inferible":false},
                 "BODY.PERSON.IDENTIFICATION":{"descripcion":"Numero de documento","resuelve_con":null,"inferible":false},
                 "BODY.GRADE.ID":{"descripcion":"Grado de escalafon (pk de catalogo)","resuelve_con":"catalogo_valores","inferible":false}}
                """,
                true,
                "[]",
                1,
                "FUNCIONARIOS",
                "/establecimientos/funcionarios/:ID",
                "PATCH",
                """
                {"PARAM.ID":"BIGINT","BODY.PERSON.EMAIL":"VARCHAR","BODY.PERSON.IDENTIFICATION":"VARCHAR",
                 "BODY.GRADE.ID":"BIGINT","BODY.STATUS":"VARCHAR","BODY.FKTARCHIVOFOTO":"FILE:perfilUsuario"}
                """,
                null,
                List.of("ADMIN", "CEVAL-SUPER_ADMINISTRADOR"));
    }

    /** POST con fechas, un FK con su herramienta de resolucion y un NUMERIC. */
    public static FilaCatalogo crearActividad() {
        return new FilaCatalogo(
                102L,
                "crear_actividad_planeador",
                "ESCRITURA",
                "Crea una actividad del planeador dentro de una unidad. Requiere confirmacion.",
                """
                {"BODY.TITULO":{"descripcion":"Titulo de la actividad","resuelve_con":null,"inferible":false},
                 "BODY.FK_TUNIDAD":{"descripcion":"Unidad a la que pertenece","resuelve_con":"unidades_listar","inferible":true},
                 "BODY.FECHA_INICIO":{"descripcion":"Fecha de inicio AAAA-MM-DD","resuelve_con":null,"inferible":false},
                 "BODY.DURACION_ESTIMADA":{"descripcion":"Duracion estimada","resuelve_con":null,"inferible":false}}
                """,
                true,
                "[]",
                1,
                "PLANEADOR",
                "/planeador/actividades",
                "POST",
                """
                {"BODY.TITULO":"VARCHAR","BODY.FK_TUNIDAD":"BIGINT","BODY.FECHA_INICIO":"DATE",
                 "BODY.DURACION_ESTIMADA":"NUMERIC"}
                """,
                null,
                List.of("CEVAL-DOCENTE", "CEVAL-SUPER_ADMINISTRADOR"));
    }

    /** GET con binds de query: fecha, pk de grupo y un entero de paginacion. */
    public static FilaCatalogo actividadesMias() {
        return new FilaCatalogo(
                103L,
                "actividades_mias_listar",
                "LECTURA",
                "Lista las actividades del docente con filtros.",
                """
                {"QUERY.SEARCH":{"descripcion":"Texto del titulo","resuelve_con":null,"inferible":true},
                 "QUERY.GRUPO":{"descripcion":"Grupo (pk)","resuelve_con":"docentes_grupos_listar","inferible":true},
                 "QUERY.DIA":{"descripcion":"Dia AAAA-MM-DD","resuelve_con":null,"inferible":true},
                 "QUERY.SIZE":{"descripcion":"Filas por pagina","resuelve_con":null,"inferible":true}}
                """,
                false,
                "[]",
                1,
                "PLANEADOR",
                "/planeador/actividades/mias",
                "GET",
                """
                {"QUERY.DIA":"DATE","QUERY.SIZE":"INT","QUERY.GRUPO":"BIGINT","QUERY.SEARCH":"VARCHAR"}
                """,
                null,
                List.of("CEVAL-DOCENTE"));
    }

    /** Mapeo real de la fila de editar_funcionario. */
    public static HerramientaDef editarFuncionarioDef() {
        return new MapeadorHerramienta().mapear(editarFuncionario());
    }

    /** Mapeo real de la fila de actividades_mias_listar. */
    public static HerramientaDef actividadesMiasDef() {
        return new MapeadorHerramienta().mapear(actividadesMias());
    }

    /** Mapeo real de la fila de crear_actividad_planeador. */
    public static HerramientaDef crearActividadDef() {
        return new MapeadorHerramienta().mapear(crearActividad());
    }
}
