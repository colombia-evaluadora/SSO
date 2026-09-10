-- ===========================================================================
-- V211 — limpieza: elimina las 3 funciones de gate que quedaron sin uso tras
-- migrar establecimiento / sedes / funcionarios / periodos academicos al
-- modelo capability + scope de V29 (CU-86e2w4xdt).
--
-- Auditoria de callers en docs/gate-permisos-por-menu-analysis.md §7: estas
-- son las UNICAS 3 realmente borrables. El resto de helpers de gate viejos
-- (fn_puede_afectar_establecimiento, fn_puede_afectar_usuarios,
-- fn_periodo_usuario_global / _establecimientos / _sedes / _puede_ver,
-- fn_resolver_establecimiento_unico) SE CONSERVAN: los siguen usando los
-- listados / reportes / matricula (V159) / PIGSE (V150), que estan fuera del
-- alcance de este cambio.
--
--   * fn_puede_afectar_sede(BIGINT): su unico caller era
--     fn_puede_afectar_usuarios; su logica quedo inlineada alli (V50 editado).
--   * fn_periodo_usuario_puede_gestionar(BIGINT) y
--     fn_periodo_usuario_puede_escribir(BIGINT, BIGINT): autorizaban la
--     escritura academica por lista fija de FK_TROL. Sus callers vivos
--     (fn_periodo_crear / _actualizar / _soft_delete / _bulk_delete,
--     fn_periodo_eval_* , fn_descanso_* , fn_criterio_prom_guardar,
--     fn_subject_guardar_bulk) pasaron a fn_periodo_gate_escritura ->
--     fn_assert_permiso_seccion. Las CREATE de estas dos ya se quitaron de
--     V37; este DROP formaliza la baja. Las versiones OBSOLETAS de V37/V38/
--     V39/V40/V103 (redefinidas mas adelante) todavia las nombran en su
--     cuerpo, pero son plpgsql y nunca se ejecutan.
--
-- IDEMPOTENTE: DROP ... IF EXISTS. Re-ejecutar es inofensivo.
-- ===========================================================================

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_puede_afectar_sede(BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_periodo_usuario_puede_gestionar(BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_periodo_usuario_puede_escribir(BIGINT, BIGINT);
