-- V81 — restricciones de validación opcionales por parámetro del
-- catálogo de queries. `QUERY.PARAM_TYPES` (V49/V62) ya declara el
-- TIPO y la OBLIGATORIEDAD de cada placeholder caller-controlled
-- (":PARAM.*" / ":BODY.*"), pero no su FORMATO: un `BIGINT` no
-- puede decir "sólo positivos" o "máximo 6 cifras", y un `TEXT` no
-- puede decir "sólo dígitos" o "entre 4 y 12 caracteres". Hoy esas
-- reglas, si existen, viven a mano dentro del SQL/PLpgSQL de cada
-- función — el cliente recibe el error críptico de un CHECK
-- constraint de PG, o peor, un 500 si la función no valida y sólo
-- explota más abajo.
--
-- Se modela como tabla propia (no una extensión más de la sintaxis
-- de PARAM_TYPES, como si fuera "BIGINT!:positive:maxDigits=6")
-- porque estas reglas son estructuradas y opcionales por campo —
-- una tabla con columnas tipadas es más legible y más fácil de
-- validar al guardar que seguir apilando sufijos sobre un string.
--
-- Cada fila es "las reglas adicionales para UN placeholder de UNA
-- query". Ausencia de fila = sin restricciones extra (sólo lo que ya
-- exige PARAM_TYPES). Toda columna de regla es NULLABLE: el autor
-- declara sólo las reglas que le interesan, el resto queda sin
-- restringir.

CREATE TABLE public.query_param_constraint (
    id              bigserial PRIMARY KEY,
    query_id        bigint NOT NULL
                        REFERENCES public.query(id_query) ON DELETE CASCADE,
    -- Mismo formato de key que PARAM_TYPES: "BODY.EDAD",
    -- "PARAM.CODIGO", etc. — namespace-prefixed, MAYÚSCULAS.
    param_key       varchar(200) NOT NULL,

    -- ---- Reglas para parámetros numéricos (BIGINT/INTEGER/SMALLINT/NUMERIC) ----
    -- Sólo admite valores > 0 (rechaza negativos; cero se rechaza
    -- también — "positivo" no es "no negativo").
    only_positive   boolean,
    -- Si es false, un valor con parte decimal se rechaza aunque el
    -- tipo declarado sea NUMERIC. Si es null/true, no se restringe.
    allow_decimals  boolean,
    -- Cantidad máxima de cifras significativas (sin contar el signo
    -- ni el punto decimal) que admite el valor.
    max_digits      integer,

    -- ---- Reglas para parámetros de texto (TEXT/VARCHAR/CHAR(1)) ----
    -- El texto debe ser enteramente numérico (sólo dígitos 0-9;
    -- ni signo ni separador decimal — para códigos/documentos que
    -- llegan como TEXT por longitud variable, p. ej. cédulas).
    numeric_text    boolean,
    min_length      integer,
    max_length      integer,

    created_date    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_query_param_constraint UNIQUE (query_id, param_key),
    CONSTRAINT ck_qpc_max_digits_positive CHECK (max_digits IS NULL OR max_digits > 0),
    CONSTRAINT ck_qpc_min_length_nonneg CHECK (min_length IS NULL OR min_length >= 0),
    CONSTRAINT ck_qpc_max_length_positive CHECK (max_length IS NULL OR max_length > 0),
    CONSTRAINT ck_qpc_length_range CHECK (
        min_length IS NULL OR max_length IS NULL OR min_length <= max_length
    )
);

CREATE INDEX idx_query_param_constraint_query ON public.query_param_constraint(query_id);

COMMENT ON TABLE public.query_param_constraint IS
    'Restricciones de formato opcionales, por placeholder, adicionales '
    'al tipo/obligatoriedad ya declarado en QUERY.PARAM_TYPES. Sin fila '
    'para un placeholder = sin restricción adicional. Validadas por '
    'query-service antes del bind (ver common.query.ParamConstraintValidator); '
    'una violación responde HTTP 400 nombrando el campo y la regla '
    'incumplida.';
COMMENT ON COLUMN public.query_param_constraint.only_positive IS
    'Numéricos: rechaza <= 0 cuando es true.';
COMMENT ON COLUMN public.query_param_constraint.allow_decimals IS
    'Numéricos: rechaza valores con parte decimal cuando es false.';
COMMENT ON COLUMN public.query_param_constraint.max_digits IS
    'Numéricos: máximo de cifras significativas admitidas.';
COMMENT ON COLUMN public.query_param_constraint.numeric_text IS
    'Texto: exige que el valor sea enteramente numérico (sólo dígitos) cuando es true.';
COMMENT ON COLUMN public.query_param_constraint.min_length IS
    'Texto: longitud mínima admitida.';
COMMENT ON COLUMN public.query_param_constraint.max_length IS
    'Texto: longitud máxima admitida.';
