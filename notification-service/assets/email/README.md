# Imágenes del correo

PNG con transparencia que usa `templates/email/password-reset.html`.

Gmail **no** renderiza SVG (ni inline, ni por `<img>`, ni en `data:` URI),
y tampoco acepta imágenes en `data:` base64. Por eso son PNG servidos por
URL: es la única forma de meter un icono en un correo sin adjuntarlo.

Se referencian desde `raw.githubusercontent.com` **fijando el SHA del
commit**, no una rama. Dos razones: la URL queda inmutable (Gmail cachea
las imágenes de forma agresiva a través de su proxy, y una URL que cambia
de contenido sirve la versión vieja durante días), y un `git push` a `dev`
no puede alterar un correo ya enviado.

Si estas imágenes se editan, hay que **volver a fijar el SHA nuevo** en la
plantilla; si no, se sigue sirviendo la versión anterior.

Cada PNG está a 3x del tamaño al que se muestra, para que no se vea
borroso en pantallas retina; el tamaño real lo fijan los atributos
`width`/`height` del `<img>`.

`logo.svg` es el original vectorial del que salió `logo.png`, aquí por si
hay que regenerarlo a otro tamaño. No lo referencia el correo.

| Archivo | Píxeles | Se muestra a | Dónde |
|---|---|---|---|
| logo.png | 480x132 | 160x44 | cabecera |
| ilustracion.png | 288x288 | 96x96 | junto al titular |
| reloj.png | 64x64 | 20x20 / 22x22 | vigencia del enlace y horario del pie |
| escudo.png | 64x64 | 22x22 | aviso verde |
| enlace.png | 64x64 | 22x22 | enlace alternativo |
| ayuda.png | 64x64 | 22x22 | pie |
| sobre.png | 64x64 | 22x22 | pie |
| telefono.png | 64x64 | 22x22 | pie |
| check.png | 64x64 | 15x15 | sin usar (ver abajo) |

`check.png` se genero para los marcadores del timeline, pero ahi se usa la
entidad `&#10003;`: Gmail bloquea las imagenes por defecto hasta que el
usuario pulsa "mostrar imagenes", y un circulo verde vacio se ve roto. El
caracter siempre esta.
