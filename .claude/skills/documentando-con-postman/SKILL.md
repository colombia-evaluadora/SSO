---
name: documentando-con-postman
description: >-
  Deja una colección Postman ejecutable que documenta un endpoint nuevo:
  login automático que encadena el token, peticiones numeradas que se pasan
  ids entre sí, y la convención de dejar la corrida en cero para poder
  repetirla. Usar al cerrar un endpoint nuevo (`CLAUDE.md` lo exige para
  query-service), al ejecutar una colección con newman, o cuando una
  colección existente falla a partir de la primera petición.
---

# Documentando un endpoint con Postman

La colección no es un anexo: es la única prueba de que el endpoint funciona
de punta a punta con un usuario real y sus permisos. Las que sirven se corren
enteras sin tocar nada.

## Forma

Un `.json` por tema en `docs/<dominio>/<tema>.postman_collection.json`, con las
peticiones **numeradas en el nombre** (`0 - Login`, `1 - Crear ...`,
`2 - Consultar ...`) porque el orden es el guion: cada una deja en una variable
lo que necesita la siguiente.

- **`0 - Login` siempre primero.** Contra `/api/auth/login`, y en su script de
  test guarda el token en una variable de colección. Ninguna otra petición pide
  credenciales.
- **Los ids se encadenan**, no se escriben a mano: la petición que crea guarda
  el id en una variable (`grupoId`, `matriculaId`...) y las siguientes la usan.
  Una colección con ids quemados caduca en cuanto cambia la base.
- **Las variables van declaradas** en el bloque `variable` de la colección, con
  un valor de ejemplo, para que se vea qué hace falta antes de correrla.
- **Un test por petición como mínimo**: el status esperado. Sin `pm.test` la
  corrida con newman siempre "pasa".

## Dejar la corrida en cero

Una colección que ensucia la base solo se puede correr una vez. Las peticiones
que crean algo tienen su pareja que lo borra al final, de modo que correrla dos
veces seguidas dé el mismo resultado. Es la misma idea que la idempotencia de
las migraciones, y por la misma razón: lo que no se puede repetir no se puede
verificar.

Cuando un paso deba dejar rastro a propósito (revisar algo a mano después), se
salta con una variable de entorno en vez de borrarse del fichero:

```js
if (!pm.environment.get("MANUAL")) { /* limpieza */ }
```

## Correrla

```bash
newman run docs/<dominio>/<tema>.postman_collection.json \
  -e docs/deploy/<entorno>.postman_environment.json
```

El entorno guarda la URL base y el usuario; la colección, nunca. Así el mismo
fichero vale contra el local y contra el servidor sin editarlo.

## Qué mirar cuando falla

Casi siempre falla en la petición 1, no en la que se está probando: el login no
guardó el token, o el usuario del entorno no tiene el rol. Antes de tocar el
endpoint, revisa qué devolvió `0 - Login` y si ese usuario tiene la fila en
`role_query` (para query-service) o la capability del menú.
