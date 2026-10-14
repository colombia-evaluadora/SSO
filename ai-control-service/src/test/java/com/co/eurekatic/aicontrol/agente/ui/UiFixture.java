package com.co.eurekatic.aicontrol.agente.ui;

import com.co.eurekatic.aicontrol.agente.catalogo.turno.AccesoMenu;
import com.co.eurekatic.aicontrol.agente.ui.contexto.CampoUi;
import com.co.eurekatic.aicontrol.agente.ui.contexto.ContextoUi;
import com.co.eurekatic.aicontrol.agente.ui.contexto.FormularioUi;
import com.co.eurekatic.aicontrol.agente.ui.contexto.OrigenFormulario;
import com.co.eurekatic.aicontrol.agente.ui.contexto.TipoCampo;
import com.co.eurekatic.aicontrol.agente.ui.registro.FormularioRegistrado;
import com.co.eurekatic.aicontrol.agente.ui.registro.Pantalla;
import com.co.eurekatic.aicontrol.agente.ui.registro.RegistroUi;

import java.util.List;
import java.util.Map;
import java.util.Set;

/** Pantallas, formularios y contexto de UI como los del registro sembrado en V557.2. */
public final class UiFixture {

    public static final Pantalla FUNCIONARIOS = new Pantalla("funcionarios", "FUNCIONARIOS", "Funcionarios",
            "/app/establecimiento-educativo/funcionarios", "Establecimiento Educativo",
            "Funcionarios: crear, editar y consultar docentes y personal.",
            List.of("colaborador", "profesor", "docente", "personal"));
    public static final Pantalla PLANEADOR = new Pantalla("planeador", "PLANEADOR", "Planeador",
            "/app/planeador/actividades", "Gestión Académica",
            "Planeador: unidades, actividades, calificacion, asistencia y observaciones.",
            List.of("planeador", "actividades", "calificar", "notas"));
    public static final Pantalla ROLES = new Pantalla("config_roles_menus", "CONFIG_ROLES_MENUS",
            "Configuración de roles y menús", "/app/administracion/roles-menus", "Administración",
            "Configuracion de roles y menus.", List.of("roles", "permisos"));

    public static final FormularioRegistrado FUNCIONARIO_CREAR = new FormularioRegistrado(
            "funcionario.crear", "FUNCIONARIOS", OrigenFormulario.FRONT, "", "");
    public static final FormularioRegistrado ACTIVIDAD = new FormularioRegistrado(
            "planeador.actividad", "PLANEADOR", OrigenFormulario.DB, "actividad_configuracion",
            "editar_actividad_planeador");

    public static final RegistroUi REGISTRO = RegistroUi.con(List.of(FUNCIONARIOS, PLANEADOR, ROLES),
            List.of(FUNCIONARIO_CREAR, ACTIVIDAD));

    /** Un docente: ve funcionarios y planeador, no la configuracion de roles. */
    public static final Map<String, AccesoMenu> MENUS_DOCENTE = Map.of(
            "FUNCIONARIOS", new AccesoMenu(true), "PLANEADOR", new AccesoMenu(false));

    public static final FormularioUi FORM_FUNCIONARIO = new FormularioUi("funcionario.crear", "", List.of(
            new CampoUi("nombres", "Nombres", TipoCampo.TEXTO, true, List.of(), false),
            new CampoUi("cargo", "Cargo", TipoCampo.SELECCION, true,
                    List.of(new CampoUi.Opcion("DOCENTE", "Docente"), new CampoUi.Opcion("RECTOR", "Rector")), false),
            new CampoUi("fechaIngreso", "Fecha de ingreso", TipoCampo.FECHA, false, List.of(), false),
            new CampoUi("perfil", "Roles y permisos", TipoCampo.TEXTO, false, List.of(), false)));

    public static final FormularioUi FORM_ACTIVIDAD = new FormularioUi("planeador.actividad", "42", List.of(
            new CampoUi("titulo", "Título", TipoCampo.TEXTO, true, List.of(), true),
            new CampoUi("recuperacionFecha", "Fecha de recuperación", TipoCampo.FECHA, false, List.of(), false)));

    public static final ContextoUi CONTEXTO = new ContextoUi("/app/establecimiento-educativo/funcionarios/crear",
            List.of(FORM_FUNCIONARIO, FORM_ACTIVIDAD), Set.of("sede", "estado"));

    private UiFixture() {
    }
}
