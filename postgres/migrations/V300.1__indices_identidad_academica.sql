-- V300.1 -- indices para public.fn_get_academico_usuario_id
-- Que hace: indexa los dos pasos de resolucion (por CUENTA y por correo).
-- Por que aqui: u_tusuario_1 es parcial (active = true) y el paso 1 busca sin
--   filtrar active, asi que no lo puede usar; el paso 2 compara UPPER(correo).
-- Depende de: V299 (fn_get_academico_usuario_id), V71 (u_tusuario_1).

CREATE INDEX IF NOT EXISTS idx_tusuario_cuenta_activo
    ON academico_test.tusuario (cuenta, active DESC, pk_tusuario);

CREATE INDEX IF NOT EXISTS idx_tusuario_correo_upper_activo
    ON academico_test.tusuario (UPPER(correo_electronico), pk_tusuario)
    WHERE active = true;
