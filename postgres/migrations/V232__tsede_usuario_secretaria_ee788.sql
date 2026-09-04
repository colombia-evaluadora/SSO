-- =============================================================================
-- V232 -- Crea el TSEDE_USUARIO que le falta a la secretaria del
-- establecimiento 788, para que no pierda el acceso a matricula cuando los
-- gates pasen al modelo de permisos dinamicos.
--
-- -----------------------------------------------------------------------------
-- El problema
-- -----------------------------------------------------------------------------
-- Hay 8 rectores/secretarias asignados UNICAMENTE por los punteros
-- TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR / _SECRETARIA, sin ninguna fila en
-- TSEDE_USUARIO. Los gates fijos actuales los aceptan porque leen esos punteros
-- directamente. El gate nuevo no puede: la capability se resuelve por
-- TROL_MENU a partir de los ROLES del usuario, y sin fila en TSEDE_USUARIO no
-- hay rol del que colgar el menu -- fn_usuario_categoria_rol_nivel devuelve
-- NULL, no entra al bypass y la capability falla.
--
-- De esos 8, cinco son usuarios de prueba (PRUEBA2025, tangamandapio,
-- "Test V120", admin@example.com, "Rector Rector"). Los tres restantes
-- parecen reales:
--
--   2214    SONIA CUELLO    rector      EE 754  IE EDUARDO SUAREZ ORCASITA
--   120705  ANA LOPEZ       secretaria  EE 754  IE EDUARDO SUAREZ ORCASITA
--   143916  EDWIN BARRIOS   secretaria  EE 788  IE NACIONAL LOPERENA
--
-- -----------------------------------------------------------------------------
-- Por que solo se arregla uno de los tres
-- -----------------------------------------------------------------------------
-- El EE 754 tiene UNA sola sede (1371) y esta INACTIVA. TSEDE_USUARIO exige
-- FK_TSEDE, y todos los gates del sistema filtran por TSEDE.ACTIVE = TRUE, asi
-- que una fila apuntando a esa sede seria inerte: no daria acceso a nada. El
-- establecimiento 754 no esta operando. Crear ahi un permiso seria ensuciar los
-- datos sin resolver nada, asi que SONIA CUELLO y ANA LOPEZ se dejan como
-- estan; si ese establecimiento se reactiva, se les crea el permiso por el
-- flujo normal (POST de sede-usuario) junto con la sede.
--
-- El EE 788 si tiene dos sedes activas (1546 CONCENTRACION SANTO DOMINGO y
-- 1547 ESCUELA ROIG Y VILLALBA), asi que EDWIN BARRIOS si puede recibir el
-- permiso.
--
-- -----------------------------------------------------------------------------
-- Forma de las filas
-- -----------------------------------------------------------------------------
-- Se copia el patron de las secretarias que ya tienen permisos: rol 9
-- (AUXILIAR_ADMINISTRATIVO) -- es el rol que llevan 9 de las 16 secretarias por
-- puntero que si tienen TSEDE_USUARIO, y el que el negocio identifica con la
-- secretaria; el rol 17 "Secretaria" existe en TROL pero tiene cero
-- asignaciones en todo el sistema. Una fila por sede activa, con la jornada de
-- los periodos de esa sede (51900 "Completa" en ambas), TLV_ESTADO 'ACTIVO' y
-- PREDETERMINADO 0.
--
-- ORDEN se calcula como el siguiente disponible para la terna
-- (sede, rol, usuario): TSEDE_USUARIO tiene dos indices unicos parciales
-- --uk_tsede_usuario_1 por jornada y uk_tsede_usuario_2 por ORDEN-- y dejarlo
-- fijo en 0 rompe cuando la persona ya tiene un permiso de ese rol en esa sede
-- con otra jornada.
--
-- -----------------------------------------------------------------------------
-- Ojo: esto seguira pasando
-- -----------------------------------------------------------------------------
-- Se creia que los permisos de rector y secretaria se creaban solos al crear la
-- sede. NO es asi en el servidor: los unicos que insertan en TSEDE_USUARIO son
-- fn_sede_usuario_crear (el endpoint explicito de asignacion) y dos funciones
-- de matricula (fn_matricula_directa_crear y fn_matricula_mover_lote, para los
-- roles 15/16 de estudiante y acudiente). fn_sed_crear no inserta nada y no hay
-- trigger que lo haga.
--
-- Es decir que van a seguir apareciendo rectores y secretarias asignados solo
-- por puntero, sin acceso bajo el modelo nuevo. La solucion de fondo es que el
-- alta de establecimiento/sede cree el permiso, o que el gate contemple el
-- puntero; ambas quedan fuera de este modulo.
--
-- Idempotente: no inserta si la fila ya existe.
-- =============================================================================

INSERT INTO academico_test.TSEDE_USUARIO (
    FK_TSEDE, FK_TROL, FK_TUSUARIO, FK_TLV_JORNADA,
    ORDEN, TLV_ESTADO, PREDETERMINADO, CREATED_BY, CREATED_AT, ACTIVE
)
SELECT s.PK_TSEDE,
       9,                                   -- AUXILIAR_ADMINISTRATIVO
       f.FK_TUSUARIO,
       j.jornada,
       COALESCE((SELECT MAX(su2.ORDEN) + 1
                   FROM academico_test.TSEDE_USUARIO su2
                  WHERE su2.FK_TSEDE    = s.PK_TSEDE
                    AND su2.FK_TROL     = 9
                    AND su2.FK_TUSUARIO = f.FK_TUSUARIO
                    AND su2.ACTIVE      = TRUE), 0),
       'ACTIVO', 0,
       'V232_seed', CURRENT_TIMESTAMP, TRUE
  FROM academico_test.TESTABLECIMIENTO e
  -- Guarda igual que en V231/V235-V237: en una base recien creada TROL esta
  -- vacia y el literal 9 de FK_TROL reventaria contra la clave ajena. Aqui el
  -- filtro por establecimiento 788 ya deja la insercion en 0 filas, pero la
  -- guarda lo hace explicito en vez de depender de ese detalle.
  JOIN academico_test.TROL r
    ON r.PK_TROL = 9
  JOIN academico_test.TFUNCIONARIO f
    ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
  JOIN academico_test.TSEDE s
    ON s.FK_TESTABLECIMIENTO = e.PK_ESTABLECIMIENTO
   AND s.ACTIVE = TRUE
  -- La jornada se toma de los periodos academicos de la sede: es la que usan
  -- los permisos existentes y la que hace que el scope por (sede, jornada)
  -- resuelva. Si la sede tuviera varias, se crea una fila por cada una.
  CROSS JOIN LATERAL (
        SELECT DISTINCT pa.FK_TLV_JORNADA AS jornada
          FROM academico_test.TPERIODO_ACADEMICO pa
         WHERE pa.FK_TSEDE = s.PK_TSEDE
           AND pa.ACTIVE = TRUE
       ) j
 WHERE e.PK_ESTABLECIMIENTO = 788
   AND e.ACTIVE = TRUE
   AND f.ACTIVE = TRUE
   AND f.FK_TUSUARIO = 143916
   AND NOT EXISTS (
       SELECT 1 FROM academico_test.TSEDE_USUARIO su
        WHERE su.FK_TSEDE       = s.PK_TSEDE
          AND su.FK_TROL        = 9
          AND su.FK_TUSUARIO    = f.FK_TUSUARIO
          AND su.FK_TLV_JORNADA = j.jornada
          AND su.ACTIVE         = TRUE
   );
