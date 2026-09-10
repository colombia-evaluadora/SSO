# Nombres normalizados de los campos de matricula

Fuente: `TMATRICULA_CAMPO.NOMBRE` (`GET /matricula/configuracion`).
Convencion: se quitan las tildes y todo caracter no alfanumerico pasa a `_`.

`En el create` indica si ese campo viaja en el body de `POST /cobertura-academica/matricula`.

## Campos del catalogo

### Información de matrícula

| # | Nombre en BD | Identificador | En el create |
|---|---|---|---|
| 1 | Sede | `SEDE` | si |
| 2 | Jornada | `JORNADA` | si |
| 3 | Grado | `GRADO` | no |
| 4 | Grupo | `GRUPO` | si |
| 5 | Estado de la matricula | `ESTADO_DE_LA_MATRICULA` | no |
| 6 | Caracter / Especialidad / Enfasis | `CARACTER_ESPECIALIDAD_ENFASIS` | si |

### Información del estudiante

| # | Nombre en BD | Identificador | En el create |
|---|---|---|---|
| 7 | Tipo de documento del estudiante | `TIPO_DE_DOCUMENTO_DEL_ESTUDIANTE` | no |
| 8 | Documento estudiante | `DOCUMENTO_ESTUDIANTE` | no |
| 9 | Nombre del estudiante | `NOMBRE_DEL_ESTUDIANTE` | no |
| 10 | Segundo nombre del estudiante | `SEGUNDO_NOMBRE_DEL_ESTUDIANTE` | no |
| 11 | Primer apellido del estudiante | `PRIMER_APELLIDO_DEL_ESTUDIANTE` | no |
| 12 | Segundo apellido del estudiante | `SEGUNDO_APELLIDO_DEL_ESTUDIANTE` | no |
| 13 | Lugar expedicion documento estudiante departamento | `LUGAR_EXPEDICION_DOCUMENTO_ESTUDIANTE_DEPARTAMENTO` | no |
| 14 | Lugar expedicion documento estudiante municipio | `LUGAR_EXPEDICION_DOCUMENTO_ESTUDIANTE_MUNICIPIO` | si |
| 15 | Fecha de nacimiento | `FECHA_DE_NACIMIENTO` | no |
| 16 | Lugar de nacimiento departamento | `LUGAR_DE_NACIMIENTO_DEPARTAMENTO` | no |
| 17 | Lugar de nacimiento municipio | `LUGAR_DE_NACIMIENTO_MUNICIPIO` | si |
| 18 | Genero del estudiante | `GENERO_DEL_ESTUDIANTE` | no |
| 19 | Etnia / Resguardo | `ETNIA_RESGUARDO` | si |

### Domicilio del estudiante

| # | Nombre en BD | Identificador | En el create |
|---|---|---|---|
| 20 | Direccion del estudiante | `DIRECCION_DEL_ESTUDIANTE` | si |
| 21 | Lugar de residencia departamento estudiante | `LUGAR_DE_RESIDENCIA_DEPARTAMENTO_ESTUDIANTE` | no |
| 22 | Lugar de residencia municipio estudiante | `LUGAR_DE_RESIDENCIA_MUNICIPIO_ESTUDIANTE` | si |

### Información de contacto del estudiante

| # | Nombre en BD | Identificador | En el create |
|---|---|---|---|
| 23 | Telefono de estudiante | `TELEFONO_DE_ESTUDIANTE` | no |
| 24 | Email estudiante | `EMAIL_ESTUDIANTE` | no |

### Información académica del año anterior

| # | Nombre en BD | Identificador | En el create |
|---|---|---|---|
| 25 | Situacion del ano anterior | `SITUACION_DEL_ANO_ANTERIOR` | si |
| 26 | Condicion del estudiante fin del ano anterior | `CONDICION_DEL_ESTUDIANTE_FIN_DEL_ANO_ANTERIOR` | si |
| 27 | Nombre de la institucion anterior | `NOMBRE_DE_LA_INSTITUCION_ANTERIOR` | si |
| 28 | Institucion bienestar de origen | `INSTITUCION_BIENESTAR_DE_ORIGEN` | si |

### Sector de origen

| # | Nombre en BD | Identificador | En el create |
|---|---|---|---|
| 29 | Proviene de sector privado | `PROVIENE_DE_SECTOR_PRIVADO` | si |
| 30 | Proviene de otro municipio | `PROVIENE_DE_OTRO_MUNICIPIO` | si |
| 31 | Cual | `CUAL` | si |

### Víctima conflicto armado

| # | Nombre en BD | Identificador | En el create |
|---|---|---|---|
| 32 | Poblacion victima conflicto | `POBLACION_VICTIMA_CONFLICTO` | si |
| 33 | Ultimo municipio expulsor | `ULTIMO_MUNICIPIO_EXPULSOR` | si |

### Información complementaria

| # | Nombre en BD | Identificador | En el create |
|---|---|---|---|
| 34 | Estrato socio economico del estudiante | `ESTRATO_SOCIO_ECONOMICO_DEL_ESTUDIANTE` | si |
| 35 | Sisben | `SISBEN` | si |
| 36 | EPS | `EPS` | si |
| 37 | ARS | `ARS` | si |
| 38 | Condiciones especiales del estudiante | `CONDICIONES_ESPECIALES_DEL_ESTUDIANTE` | si |
| 39 | Talento del estudiante | `TALENTO_DEL_ESTUDIANTE` | si |

### Subsidio o beneficios

| # | Nombre en BD | Identificador | En el create |
|---|---|---|---|
| 40 | Subsidiado | `SUBSIDIADO` | si |
| 41 | Fuente de recursos | `FUENTE_DE_RECURSOS` | si |
| 42 | Alumnos madre cabeza de familia | `ALUMNOS_MADRE_CABEZA_DE_FAMILIA` | si |
| 43 | Hijos de madre cabeza de familia | `HIJOS_DE_MADRE_CABEZA_DE_FAMILIA` | si |
| 44 | Veteranos de la fuerza publica | `VETERANOS_DE_LA_FUERZA_PUBLICA` | si |
| 45 | Heroes de la nacion | `HEROES_DE_LA_NACION` | si |

### Información del acudiente

| # | Nombre en BD | Identificador | En el create |
|---|---|---|---|
| 46 | Parentesco | `PARENTESCO` | si |
| 47 | Nombre del acudiente | `NOMBRE_DEL_ACUDIENTE` | no |
| 48 | Segundo nombre del acudiente | `SEGUNDO_NOMBRE_DEL_ACUDIENTE` | no |
| 49 | Primer apellido del acudiente | `PRIMER_APELLIDO_DEL_ACUDIENTE` | no |
| 50 | Segundo apellido del acudiente | `SEGUNDO_APELLIDO_DEL_ACUDIENTE` | no |
| 51 | Tipo de documento del acudiente | `TIPO_DE_DOCUMENTO_DEL_ACUDIENTE` | no |
| 52 | Documento acudiente | `DOCUMENTO_ACUDIENTE` | no |
| 53 | Lugar expedicion documento acudiente departamento | `LUGAR_EXPEDICION_DOCUMENTO_ACUDIENTE_DEPARTAMENTO` | no |
| 54 | Lugar expedicion documento acudiente municipio | `LUGAR_EXPEDICION_DOCUMENTO_ACUDIENTE_MUNICIPIO` | si |

### Domicilio del acudiente

| # | Nombre en BD | Identificador | En el create |
|---|---|---|---|
| 62 | Direccion de acudiente | `DIRECCION_DE_ACUDIENTE` | si |
| 63 | Lugar de residencia departamento acudiente | `LUGAR_DE_RESIDENCIA_DEPARTAMENTO_ACUDIENTE` | no |
| 64 | Lugar de residencia municipio acudiente | `LUGAR_DE_RESIDENCIA_MUNICIPIO_ACUDIENTE` | si |

### Información de contacto del acudiente

| # | Nombre en BD | Identificador | En el create |
|---|---|---|---|
| 55 | Telefono de acudiente | `TELEFONO_DE_ACUDIENTE` | no |
| 56 | Email acudiente | `EMAIL_ACUDIENTE` | no |

### Información laboral del acudiente

| # | Nombre en BD | Identificador | En el create |
|---|---|---|---|
| 57 | Profesion acudiente | `PROFESION_ACUDIENTE` | si |
| 58 | Nombre de la entidad acudiente | `NOMBRE_DE_LA_ENTIDAD_ACUDIENTE` | si |
| 59 | Direccion de la entidad acudiente | `DIRECCION_DE_LA_ENTIDAD_ACUDIENTE` | si |
| 60 | Telefono de la entidad acudiente | `TELEFONO_DE_LA_ENTIDAD_ACUDIENTE` | si |
| 61 | Cargo entidad acudiente | `CARGO_ENTIDAD_ACUDIENTE` | si |

## Campos del body que NO salen del catalogo

Ninguno de estos se puede gobernar desde `GET /matricula/configuracion`.

### Estan en el formulario, pero el catalogo no los contempla

| Identificador | Detalle |
|---|---|
| `DOCUMENTO_DE_IDENTIDAD_DEL_ESTUDIANTE` | Archivo de soporte. OBLIGATORIO. |
| `CERTIFICADO_DE_ESTUDIOS_DEL_ANO_ANTERIOR` | Archivo de soporte. OBLIGATORIO. |
| `CERTIFICADO_MEDICO_DEL_ESTUDIANTE` | Archivo de soporte. Opcional. |
| `FOTO_DEL_ESTUDIANTE` | Archivo de soporte. Opcional. |
| `OTROS_DOCUMENTOS_RELEVANTES` | Archivo de soporte. Opcional, 0..N: repite la misma key por cada archivo. |

### No estan ni en el formulario ni en el catalogo

Columnas reales del DDL, expuestas como parametros **opcionales** para no
perder capacidad. Hoy el front no tiene de donde sacar su valor: o se agregan
al formulario y al catalogo, o simplemente no se mandan.

| Identificador | Columna | Detalle |
|---|---|---|
| `ESTUDIANTE_NUEVO` | 'S' o 'N'. | 'S' o 'N'. Columna NOT NULL de TMATRICULA; el formulario no la pide. |
| `ZONA_ACUDIENTE` | TPADRE.FK_TLV_ZONA | TPADRE.FK_TLV_ZONA (categoria ZONA). El formulario no lo pide. |
| `NIVEL_EDUCATIVO_ACUDIENTE` | TPADRE.FK_TLV_NIVEL_EDUCATIVO | TPADRE.FK_TLV_NIVEL_EDUCATIVO. El formulario no lo pide. |
| `ESTADO_CIVIL_ACUDIENTE` | TPADRE.FK_TLV_ESTADO_CIVIL | TPADRE.FK_TLV_ESTADO_CIVIL. El formulario no lo pide. |
| `OCUPACION_ACUDIENTE` | TPADRE.OCUPACION | TPADRE.OCUPACION. El formulario pide PROFESION, no ocupacion. |
| `ACUDIENTE` | TNUCLEO_FAMILIAR.ACUDIENTE, | TNUCLEO_FAMILIAR.ACUDIENTE, 'S' o 'N'. El formulario no lo pide. |
| `ASISTE_REUNIONES` | TNUCLEO_FAMILIAR.ASISTE_REUNIONES, | TNUCLEO_FAMILIAR.ASISTE_REUNIONES, 'S' o 'N'. El formulario no lo pide. |
| `ASISTE_INFORMES` | TNUCLEO_FAMILIAR.ASISTE_INFORMES, | TNUCLEO_FAMILIAR.ASISTE_INFORMES, 'S' o 'N'. El formulario no lo pide. |
| `TIPO_EMPLEO_ACUDIENTE` | TNUCLEO_FAMILIAR.FK_TLV_TIPO_EMPLEO | TNUCLEO_FAMILIAR.FK_TLV_TIPO_EMPLEO. El formulario no lo pide. |
| `FRECUENCIA_DOMICILIO_ACUDIENTE` | TNUCLEO_FAMILIAR.FK_TLV_FRECUENCIA_DOMICILIO | TNUCLEO_FAMILIAR.FK_TLV_FRECUENCIA_DOMICILIO. El formulario no lo pide. |

### Tecnicos

| Identificador | Detalle |
|---|---|
| `PK_USUARIO_ESTUDIANTE` | pkTusuario devuelto por POST /register/usuario. OJO: NO es idUser. |
| `PK_USUARIO_ACUDIENTE` | pkTusuario del acudiente (POST /register/usuario). |
