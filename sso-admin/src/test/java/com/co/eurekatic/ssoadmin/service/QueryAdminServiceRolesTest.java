package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.App;
import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.entity.Query;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.repository.AppRepository;
import com.co.eurekatic.common.repository.MicroserviceRepository;
import com.co.eurekatic.common.repository.QueryRepository;
import com.co.eurekatic.common.repository.RoleRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.when;

/**
 * Un role_query sólo debe poder atarse a queries de roles que
 * pertenezcan a alguno de los apps del microservicio de esa query —
 * antes de este cambio {@code roleRepo.findAll()} dejaba bindear
 * cualquier rol a cualquier query, sin importar de qué app fuera cada
 * uno (p. ej. un rol de "académico" atado a una query de "eval-col").
 *
 * <p>La relación Microservice↔App que el admin-ui usa de verdad hoy es
 * la M:N {@code app_microservice} (pestaña "Microservices" del
 * formulario de App, {@code AppService#bindMicroservice}) — se
 * consulta acá vía {@link AppRepository#findByMicroserviceId}. El FK
 * "primario" {@code Microservice#getApp()} no tiene ningún formulario
 * que lo exponga hoy, pero {@code QueryAdminService} lo sigue contando
 * por si acaso — ver los últimos dos tests.
 */
@ExtendWith(MockitoExtension.class)
class QueryAdminServiceRolesTest {

    @Mock QueryRepository queryRepo;
    @Mock RoleRepository roleRepo;
    @Mock MicroserviceRepository microserviceRepo;
    @Mock AppRepository appRepo;
    @Mock PathRegistryNotifier pathRegistryNotifier;
    @InjectMocks QueryAdminService service;

    private static Role role(long id, String name) {
        Role r = new Role();
        r.setId(id);
        r.setName(name);
        return r;
    }

    private static App appConRoles(long id, String name, Role... roles) {
        App a = new App();
        a.setId(id);
        a.setName(name);
        for (Role r : roles) {
            a.addRole(r);
        }
        return a;
    }

    private static Microservice microservicio(long id) {
        Microservice m = new Microservice();
        m.setId(id);
        m.setServiceId("eval-col");
        return m;
    }

    private static Query query(long id, Microservice microservice) {
        Query q = new Query();
        q.setId(id);
        q.setMicroservice(microservice);
        return q;
    }

    // ---------- vía app_microservice (M:N — la que el admin-ui usa hoy) ----------

    @Test
    void bindRoleAceptaUnRolDeUnAppAtadoPorMN() {
        Role rolEvalCol = role(1L, "EVAL_COL_DOCENTE");
        App evalCol = appConRoles(10L, "eval-col", rolEvalCol);
        Microservice m = microservicio(20L);
        Query q = query(100L, m);

        when(queryRepo.findById(100L)).thenReturn(Optional.of(q));
        when(roleRepo.findById(1L)).thenReturn(Optional.of(rolEvalCol));
        when(appRepo.findByMicroserviceId(20L)).thenReturn(List.of(evalCol));

        service.bindRole(100L, 1L);

        assertThat(q.getRoles()).contains(rolEvalCol);
    }

    @Test
    void bindRoleRechazaUnRolDeOtroApp() {
        Role rolEvalCol = role(1L, "EVAL_COL_DOCENTE");
        Role rolAcademico = role(2L, "ACADEMICO_RECTOR");
        App evalCol = appConRoles(10L, "eval-col", rolEvalCol);
        Microservice m = microservicio(20L);
        Query q = query(100L, m);

        when(queryRepo.findById(100L)).thenReturn(Optional.of(q));
        when(roleRepo.findById(2L)).thenReturn(Optional.of(rolAcademico));
        when(appRepo.findByMicroserviceId(20L)).thenReturn(List.of(evalCol));

        assertThatThrownBy(() -> service.bindRole(100L, 2L))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("ACADEMICO_RECTOR");
        assertThat(q.getRoles()).doesNotContain(rolAcademico);
    }

    /** Un microservicio atado a VARIOS apps por la M:N acepta la unión de sus roles. */
    @Test
    void bindRoleAceptaLaUnionDeRolesDeVariosAppsAtados() {
        Role rolEvalCol = role(1L, "EVAL_COL_DOCENTE");
        Role rolAcademico = role(2L, "ACADEMICO_RECTOR");
        App evalCol = appConRoles(10L, "eval-col", rolEvalCol);
        App academico = appConRoles(11L, "academico", rolAcademico);
        Microservice m = microservicio(20L);
        Query q = query(100L, m);

        when(queryRepo.findById(100L)).thenReturn(Optional.of(q));
        when(roleRepo.findById(2L)).thenReturn(Optional.of(rolAcademico));
        when(appRepo.findByMicroserviceId(20L)).thenReturn(List.of(evalCol, academico));

        service.bindRole(100L, 2L);

        assertThat(q.getRoles()).contains(rolAcademico);
    }

    /** Un app atado por M:N pero sin ningún rol propio bloquea todo bind — hay app, simplemente no autoriza a nadie. */
    @Test
    void bindRoleRechazaCualquierRolSiElAppAtadoNoTieneRoles() {
        Role cualquiera = role(5L, "CUALQUIERA");
        App evalColSinRoles = appConRoles(10L, "eval-col");
        Microservice m = microservicio(20L);
        Query q = query(100L, m);

        when(queryRepo.findById(100L)).thenReturn(Optional.of(q));
        when(roleRepo.findById(5L)).thenReturn(Optional.of(cualquiera));
        when(appRepo.findByMicroserviceId(20L)).thenReturn(List.of(evalColSinRoles));

        assertThatThrownBy(() -> service.bindRole(100L, 5L))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void getRolesForQueryCheckedSoloListaLosDelAppAtadoPorMN() {
        Role rolEvalCol = role(1L, "EVAL_COL_DOCENTE");
        Role rolAcademico = role(2L, "ACADEMICO_RECTOR");
        App evalCol = appConRoles(10L, "eval-col", rolEvalCol);
        Microservice m = microservicio(20L);
        Query q = query(100L, m);

        when(queryRepo.findById(100L)).thenReturn(Optional.of(q));
        when(appRepo.findByMicroserviceId(20L)).thenReturn(List.of(evalCol));

        var checked = service.getRolesForQueryChecked(100L);

        assertThat(checked).extracting(QueryAdminService.RoleChecked::roleId)
                .containsExactly(1L);
        assertThat(checked).noneMatch(rc -> rc.name().equals("ACADEMICO_RECTOR"));
    }

    // ---------- sin ningún app atado (ni M:N ni FK primario) — permisivo ----------

    /** Sin microservicio asignado (query "global") no hay app contra el cual filtrar — se mantiene permisivo. */
    @Test
    void bindRoleSinMicroservicioEsPermisivo() {
        Role cualquiera = role(3L, "CUALQUIERA");
        Query q = query(100L, null);

        when(queryRepo.findById(100L)).thenReturn(Optional.of(q));
        when(roleRepo.findById(3L)).thenReturn(Optional.of(cualquiera));

        service.bindRole(100L, 3L);

        assertThat(q.getRoles()).contains(cualquiera);
    }

    /** Microservicio sin ningún app atado (ni por M:N ni por FK primario) tampoco filtra. */
    @Test
    void bindRoleConMicroservicioSinNingunAppAtadoEsPermisivo() {
        Role cualquiera = role(4L, "CUALQUIERA");
        Microservice m = microservicio(20L);
        Query q = query(100L, m);

        when(queryRepo.findById(100L)).thenReturn(Optional.of(q));
        when(roleRepo.findById(4L)).thenReturn(Optional.of(cualquiera));
        when(appRepo.findByMicroserviceId(20L)).thenReturn(List.of());

        service.bindRole(100L, 4L);

        assertThat(q.getRoles()).contains(cualquiera);
    }

    /** Sin app que filtrar, la lista completa de roles vuelve a estar disponible (comportamiento previo). */
    @Test
    void getRolesForQueryCheckedSinAppListaTodos() {
        Role uno = role(1L, "UNO");
        Role dos = role(2L, "DOS");
        Query q = query(100L, null);

        when(queryRepo.findById(100L)).thenReturn(Optional.of(q));
        when(roleRepo.findAll()).thenReturn(List.of(uno, dos));

        var checked = service.getRolesForQueryChecked(100L);

        assertThat(checked).extracting(QueryAdminService.RoleChecked::roleId)
                .containsExactlyInAnyOrder(1L, 2L);
    }

    // ---------- vía Microservice#getApp() (FK primario — sin formulario hoy, pero se sigue contando) ----------

    @Test
    void bindRoleAceptaUnRolDelAppPrimarioDelMicroservicio() {
        Role rolEvalCol = role(1L, "EVAL_COL_DOCENTE");
        App evalCol = appConRoles(10L, "eval-col", rolEvalCol);
        Microservice m = microservicio(20L);
        m.setApp(evalCol);
        Query q = query(100L, m);

        when(queryRepo.findById(100L)).thenReturn(Optional.of(q));
        when(roleRepo.findById(1L)).thenReturn(Optional.of(rolEvalCol));
        when(appRepo.findByMicroserviceId(20L)).thenReturn(List.of());

        service.bindRole(100L, 1L);

        assertThat(q.getRoles()).contains(rolEvalCol);
    }

    /** El mismo app por las dos vías a la vez no lo cuenta dos veces ni cambia el resultado. */
    @Test
    void bindRoleConElMismoAppPorLasDosViasFuncionaIgual() {
        Role rolEvalCol = role(1L, "EVAL_COL_DOCENTE");
        App evalCol = appConRoles(10L, "eval-col", rolEvalCol);
        Microservice m = microservicio(20L);
        m.setApp(evalCol);
        Query q = query(100L, m);

        when(queryRepo.findById(100L)).thenReturn(Optional.of(q));
        when(roleRepo.findById(1L)).thenReturn(Optional.of(rolEvalCol));
        when(appRepo.findByMicroserviceId(20L)).thenReturn(List.of(evalCol));

        service.bindRole(100L, 1L);

        assertThat(q.getRoles()).contains(rolEvalCol);
    }
}
