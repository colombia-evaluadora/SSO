-- ===========================================================================
-- V467 - Todo establecimiento nuevo nace con un fondo de boletin.
--   fn_establecimiento_fondo_boletin_defecto()  el fondo por defecto
--   trg_establecimiento_fondo_boletin           BEFORE INSERT
--
-- V465 dejo la columna, pero en NULL: un colegio recien creado imprimia sus
-- boletines sobre blanco hasta que alguien le eligiera uno. Se le asigna el
-- primero (fondo1, Oficio), que puede cambiar despues desde la pantalla.
-- El resto -- por que por NOMBRE, por que BEFORE -- en los COMMENT.
--
-- Depende de: V465 (la columna), images/ + scripts/cargar-imagenes-s3.py.
-- Idempotente: CREATE OR REPLACE y DROP TRIGGER IF EXISTS antes de crearlo.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_establecimiento_fondo_boletin_defecto()
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $function$
    SELECT a.PK_TARCHIVO
      FROM academico_test.TARCHIVO a
     WHERE a.ETIQUETA = 'fondoBoletin'
       AND a.NOMBRE   = 'fondo1/boletinOficio.jpg'
       AND a.ACTIVE   = TRUE
     ORDER BY a.PK_TARCHIVO
     LIMIT 1;
$function$;

COMMENT ON FUNCTION academico_test.fn_establecimiento_fondo_boletin_defecto()
    IS 'El fondo de boletin que recibe un establecimiento nuevo: el primer modelo (fondo1) en formato Oficio, que es el tamaño de la plantilla del boletin. Se resuelve por NOMBRE y no por pk porque los pk de TARCHIVO dependen del orden en que se cargaron las imagenes y no coinciden entre entornos, mientras que el nombre lo fija la ruta dentro de images/. Tampoco se toma MIN(PK_TARCHIVO) de la etiqueta: eso seria "el primero que alguien subio" y cambiaria de significado con solo reordenar una carga. Devuelve NULL donde las imagenes no esten cargadas -- en CI, por ejemplo --, y entonces el establecimiento nace sin fondo y su boletin se imprime sobre blanco, que es el comportamiento degradado de V465. V467.';


-- BEFORE y no AFTER: el valor es una columna de la propia fila. Solo actua
-- sobre NULL, para no pisar a quien elija el fondo al crear.
CREATE OR REPLACE FUNCTION academico_test.fn_establecimiento_fondo_boletin_trg()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.FK_TARCHIVO_FONDO_BOLETIN IS NULL THEN
        NEW.FK_TARCHIVO_FONDO_BOLETIN :=
            academico_test.fn_establecimiento_fondo_boletin_defecto();
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_establecimiento_fondo_boletin_trg()
    IS 'Trigger BEFORE INSERT en TESTABLECIMIENTO: si el alta no trae fondo de boletin, le pone el que devuelve fn_establecimiento_fondo_boletin_defecto. Solo actua sobre NULL, de modo que quien cree un establecimiento eligiendo su fondo manda. Va BEFORE y no AFTER porque el valor es una columna de la propia fila: se escribe en NEW y se ahorra el UPDATE extra -- y con el, una segunda pasada del trigger de auditoria sobre la misma alta. Se dispara tanto desde fn_est_crear como desde un INSERT directo, que es la razon de que sea un trigger y no un parametro de la funcion de alta. V467.';


DROP TRIGGER IF EXISTS trg_establecimiento_fondo_boletin ON academico_test.TESTABLECIMIENTO;
CREATE TRIGGER trg_establecimiento_fondo_boletin
    BEFORE INSERT ON academico_test.TESTABLECIMIENTO
    FOR EACH ROW
    EXECUTE FUNCTION academico_test.fn_establecimiento_fondo_boletin_trg();
