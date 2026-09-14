# -*- coding: utf-8 -*-
"""
Tokenizador y extractor de sentencias SQL para las migraciones Flyway del repo.

No es un parser de SQL: es un *splitter* correcto (respeta comentarios,
literales y dollar-quoting de PL/pgSQL) mas un conjunto de extractores por
expresion regular sobre cada sentencia ya aislada. Esa separacion es la que
hace que el analisis sea fiable: el 90% de los falsos positivos de un grep
sobre migraciones vienen de matchear dentro de un cuerpo de funcion o de un
comentario, y aca eso no puede pasar.

Todo lo que no se logra clasificar se reporta como `unparsed` en vez de
descartarse en silencio -- la cobertura del analisis es un dato visible.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field


# ---------------------------------------------------------------------------
# Splitter
# ---------------------------------------------------------------------------

@dataclass
class Statement:
    """Una sentencia SQL de nivel superior, con su posicion en el archivo."""
    text: str
    line: int          # 1-indexed, donde arranca la sentencia
    raw: str           # texto tal cual, con comentarios

    @property
    def head(self) -> str:
        """Primeras palabras normalizadas, para clasificar rapido."""
        return re.sub(r"\s+", " ", self.text.strip()[:120]).upper()


def strip_comments(sql: str, deep: bool = False) -> str:
    """
    Quita `-- ...` y `/* ... */` sin tocar literales ni dollar-quotes.

    Con `deep=True` los bloques `$$ ... $$` dejan de ser opacos: tambien se
    limpian los comentarios de adentro de los cuerpos PL/pgSQL. Hace falta
    para buscar llamadas reales a funciones -- media docena de cuerpos
    mencionan otras funciones en un comentario interno.
    """
    out: list[str] = []
    i, n = 0, len(sql)
    while i < n:
        ch = sql[i]

        # literal de cadena: '' escapa la comilla
        if ch == "'":
            j = i + 1
            while j < n:
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            out.append(sql[i:j])
            i = j
            continue

        # identificador entre comillas dobles
        if ch == '"':
            j = sql.find('"', i + 1)
            j = n if j == -1 else j + 1
            out.append(sql[i:j])
            i = j
            continue

        # dollar quoting: $$ ... $$ o $tag$ ... $tag$
        if ch == "$" and not deep:
            m = re.match(r"\$[A-Za-z_]\w*\$|\$\$", sql[i:])
            if m:
                tag = m.group(0)
                j = sql.find(tag, i + len(tag))
                j = n if j == -1 else j + len(tag)
                out.append(sql[i:j])
                i = j
                continue

        # comentario de linea
        if sql.startswith("--", i):
            j = sql.find("\n", i)
            j = n if j == -1 else j
            out.append("\n" * sql.count("\n", i, j))  # preserva numeracion
            i = j
            continue

        # comentario de bloque
        if sql.startswith("/*", i):
            j = sql.find("*/", i + 2)
            j = n if j == -1 else j + 2
            out.append("\n" * sql.count("\n", i, j))
            i = j
            continue

        out.append(ch)
        i += 1

    return "".join(out)


def split_statements(sql: str) -> list[Statement]:
    """Parte el archivo en sentencias por `;` de nivel superior."""
    clean = strip_comments(sql)
    stmts: list[Statement] = []

    i, n = 0, len(clean)
    start = 0
    while i < n:
        ch = clean[i]

        if ch == "'":
            j = i + 1
            while j < n:
                if clean[j] == "'":
                    if j + 1 < n and clean[j + 1] == "'":
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            i = j
            continue

        if ch == '"':
            j = clean.find('"', i + 1)
            i = n if j == -1 else j + 1
            continue

        if ch == "$":
            m = re.match(r"\$[A-Za-z_]\w*\$|\$\$", clean[i:])
            if m:
                tag = m.group(0)
                j = clean.find(tag, i + len(tag))
                i = n if j == -1 else j + len(tag)
                continue

        if ch == ";":
            body = clean[start:i]
            if body.strip():
                stmts.append(Statement(
                    text=body.strip(),
                    line=clean.count("\n", 0, start) + 1,
                    raw=body,
                ))
            start = i + 1

        i += 1

    tail = clean[start:]
    if tail.strip():
        stmts.append(Statement(
            text=tail.strip(),
            line=clean.count("\n", 0, start) + 1,
            raw=tail,
        ))
    return stmts


# ---------------------------------------------------------------------------
# Utilidades de parseo
# ---------------------------------------------------------------------------

def match_paren(text: str, open_pos: int) -> int:
    """Indice del `)` que cierra el `(` en `open_pos` (o len(text))."""
    depth = 0
    i, n = open_pos, len(text)
    while i < n:
        ch = text[i]
        if ch == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            i = j
            continue
        if ch == "$":
            m = re.match(r"\$[A-Za-z_]\w*\$|\$\$", text[i:])
            if m:
                tag = m.group(0)
                j = text.find(tag, i + len(tag))
                i = n if j == -1 else j + len(tag)
                continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n


def find_top_level(text: str, pattern: str) -> int:
    """
    Posicion del primer match de `pattern` fuera de literales, dollar-quotes
    y parentesis. -1 si no hay. Imprescindible para cortar la lista de un
    `INSERT ... SELECT`: los cuerpos de query del catalogo llevan `FROM`
    dentro de la cadena, y un regex a secas corta en el lugar equivocado.
    """
    rx = re.compile(pattern, re.I)
    depth = 0
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            i = j
            continue
        if ch == "$":
            m = re.match(r"\$[A-Za-z_]\w*\$|\$\$", text[i:])
            if m:
                tag = m.group(0)
                j = text.find(tag, i + len(tag))
                i = n if j == -1 else j + len(tag)
                continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif depth == 0:
            m = rx.match(text, i)
            if m:
                return i
        i += 1
    return -1


def dollar_bodies(text: str) -> list[str]:
    """Contenido de cada bloque $$ ... $$ / $tag$ ... $tag$ del texto."""
    out, i, n = [], 0, len(text)
    while i < n:
        m = re.compile(r"\$[A-Za-z_]\w*\$|\$\$").search(text, i)
        if not m:
            break
        tag = m.group(0)
        end = text.find(tag, m.end())
        if end == -1:
            break
        out.append(text[m.end():end])
        i = end + len(tag)
    return out


def split_top_level(text: str, sep: str = ",") -> list[str]:
    """Parte por `sep` ignorando parentesis, literales y dollar-quotes."""
    parts, depth, cur = [], 0, []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            cur.append(text[i:j])
            i = j
            continue
        if ch == "$":
            m = re.match(r"\$[A-Za-z_]\w*\$|\$\$", text[i:])
            if m:
                tag = m.group(0)
                j = text.find(tag, i + len(tag))
                j = n if j == -1 else j + len(tag)
                cur.append(text[i:j])
                i = j
                continue
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == sep and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    parts.append("".join(cur))
    return [p.strip() for p in parts if p.strip()]


PG_TYPES = (
    r"bigint|integer|int|smallint|numeric|decimal|real|double\s+precision|"
    r"character\s+varying|varchar|character|char|text|boolean|bool|date|"
    r"timestamp(?:\s+with(?:out)?\s+time\s+zone)?|time(?:stamptz)?|jsonb|json|"
    r"uuid|bytea|void|record|anyelement|inet|money|interval"
)


@dataclass
class FuncParam:
    name: str
    type: str
    has_default: bool


def parse_params(param_text: str) -> list[FuncParam]:
    """Parsea la lista de parametros de una funcion PL/pgSQL."""
    params: list[FuncParam] = []
    for chunk in split_top_level(param_text):
        if not chunk:
            continue
        has_default = bool(re.search(r"\bDEFAULT\b|\s:=\s", chunk, re.I))
        body = re.split(r"\bDEFAULT\b", chunk, flags=re.I)[0].strip()
        body = re.sub(r"^\s*(IN|OUT|INOUT|VARIADIC)\s+", "", body, flags=re.I)

        # `nombre tipo` o solo `tipo`
        m = re.match(rf"^([A-Za-z_]\w*)\s+((?:{PG_TYPES})[\w\s\[\]().]*)$", body, re.I)
        if m:
            name, typ = m.group(1), m.group(2)
        else:
            m2 = re.match(rf"^((?:{PG_TYPES})[\w\s\[\]().]*)$", body, re.I)
            if m2:
                name, typ = "", m2.group(1)
            else:
                bits = body.split()
                name = bits[0] if len(bits) > 1 else ""
                typ = " ".join(bits[1:]) if len(bits) > 1 else body
        params.append(FuncParam(
            name=name.lower(),
            type=normalize_type(typ),
            has_default=has_default,
        ))
    return params


def normalize_type(t: str) -> str:
    t = re.sub(r"\s+", " ", t.strip().lower())
    t = re.sub(r"::.*$", "", t)
    t = re.sub(r"\(\s*\d+(\s*,\s*\d+)?\s*\)", "", t)   # varchar(120) -> varchar
    alias = {
        "character varying": "varchar",
        "int": "integer",
        "int4": "integer",
        "int8": "bigint",
        "bool": "boolean",
        "timestamp without time zone": "timestamp",
        "timestamp with time zone": "timestamptz",
        "decimal": "numeric",
    }
    for long, short in alias.items():
        if t == long or t.startswith(long + "["):
            t = t.replace(long, short, 1)
    return t.strip()


def count_call_args(text: str, call_open: int) -> int | None:
    """Cantidad de argumentos de una llamada cuyo `(` esta en call_open."""
    close = match_paren(text, call_open)
    if close >= len(text):
        return None
    inner = text[call_open + 1:close].strip()
    if not inner:
        return 0
    return len(split_top_level(inner))
