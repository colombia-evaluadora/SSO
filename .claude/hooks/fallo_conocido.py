r"""Traduce un fallo conocido de este repo a su causa real.

PostToolUseFailure: cuando un comando revienta, el mensaje suele ser cierto y
poco util -- `42501`, `Could not resolve dependencies`, `charmap codec can't
encode`. En este repo cada uno de esos tiene una causa concreta que ya se
investigo una vez, y sin esto se vuelve a investigar desde cero.

No bloquea nada (el comando ya fallo): solo devuelve la pista como contexto.
"""
from __future__ import annotations

import json
import re
import sys

# (patron, pista). El orden importa: gana el primero que casa.
PISTAS: list[tuple[str, str]] = [
    (r"\b42501\b|insufficient_privilege",
     "42501 = el gate de permisos rechazo la llamada. Las tres causas habituales "
     "en este repo: (1) el CODIGO del menu se comparo con tildes y el real no las "
     "lleva (V396); (2) se omitieron los parametros de alcance -- establecimiento, "
     "sede, jornada -- de fn_assert_permiso_seccion, que no es 'sin restriccion' "
     "sino no comprobarla; (3) el usuario no tiene la fila en role_query (no hay "
     "bypass de admin). Ojo tambien al gate dual: el rol puede estar en el JWT y "
     "no en TSEDE_USUARIO."),
    (r"\b23503\b|foreign_key_violation",
     "23503 = tiene dependientes. Es el codigo que el esquema usa a proposito para "
     "'no se puede eliminar porque algo cuelga de esto', y el gateway lo traduce a "
     "409. Si lo devuelve un borrado, funciona como debe; si lo devuelve un INSERT, "
     "falta la fila padre (o esta con ACTIVE=FALSE y el check lo exige)."),
    (r"\b23505\b|duplicate key value",
     "23505 = unicidad. Cuidado: muchas de las UNIQUE de academico_test son "
     "indices parciales 'WHERE active = true' (V65), asi que un ON CONFLICT que "
     "no nombre el mismo predicado no casa con el indice y no atrapa nada."),
    (r"\b42725\b|is not unique|function .* is ambiguous",
     "42725 = hay dos sobrecargas vivas de la funcion. Cambiar la aridad exige "
     "DROP FUNCTION IF EXISTS de la firma vieja antes del CREATE; sin eso las dos "
     "conviven y toda llamada sin tipos explicitos es ambigua."),
    (r"charmap.*codec|UnicodeDecodeError|UnicodeEncodeError|cp1252",
     "El locale de esta maquina es cp1252. En Python pasa encoding='utf-8' "
     "explicito en read_text/write_text/open: sin el, un .sql con tildes se lee o "
     "se guarda roto y llega asi a produccion."),
    (r"Could not resolve dependencies|Could not find artifact|Failed to execute goal.*:compile",
     "Maven no encuentra un modulo hermano. Este repo es multi-modulo: instala "
     "primero el padre con `mvn -q -N install` y compila con `-am` "
     "(`mvn -pl <modulo> -am test`), o el modulo `common` no existe para el resto."),
    (r"Validate failed.*checksum|Migration checksum mismatch",
     "Flyway: el checksum de una migracion editada no coincide con el que registro "
     "el servidor. Se resuelve con `flyway repair` y re-ejecutando el SQL cambiado "
     "-- y ojo, re-aplicar SOLO el fichero editado revive sus definiciones viejas y "
     "se lleva por delante las migraciones posteriores que las reescribieron "
     "(skill `reaplicando-migraciones`)."),
    (r"404|Not Found",
     "Si es una ruta de query-service recien insertada en public.query: el registro "
     "de rutas se lee al arrancar, asi que la fila no existe hasta que se reinicia "
     "el contenedor query-service-<serviceid>. La ruta es api/<serviceid>/..."),
]


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0

    texto = json.dumps(data.get("error") or data.get("tool_response") or "", ensure_ascii=False)
    if not texto:
        return 0

    for patron, pista in PISTAS:
        if re.search(patron, texto, re.I):
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PostToolUseFailure",
                    "additionalContext": pista,
                }
            }, ensure_ascii=False))
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
