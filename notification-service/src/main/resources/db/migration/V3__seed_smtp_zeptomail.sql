-- ---------------------------------------------------------------
-- ZeptoMail (Zoho) como proveedor SMTP de correo.
--
-- Entra con priority 2: por delante de smtp-gmail (3), que queda de
-- respaldo automático. EmailSender recorre el roster por prioridad y
-- salta al siguiente proveedor cuando uno falla, así que si ZeptoMail
-- rechaza un envío el correo sigue saliendo por Gmail.
--
-- smtp-brevo conserva la priority 1 pero está deshabilitado, así que
-- no compite; el día que se habilite pasará a ser el primario sin
-- tocar esta fila.
--
-- Las credenciales NO viven aquí: username_env / password_env son
-- NOMBRES de variables de entorno que SmtpEmailProvider resuelve con
-- System.getenv en tiempo de envío. Hay que darlas de alta en dos
-- sitios o la fila se auto-desactiva por "credentials missing":
--   1. el bloque environment: de notification-service en
--      docker-compose.yml (si no, no llegan al contenedor)
--   2. el secreto de repo TEST_ENV_FILE, que es de donde el deploy
--      escribe /opt/sso/.env en cada despliegue
--
-- El usuario SMTP de ZeptoMail es la cadena literal `emailapikey`
-- para todas las cuentas; lo que identifica la cuenta es el token,
-- que va en la contraseña.
--
-- OJO con el remitente: ZeptoMail sólo acepta enviar desde dominios
-- verificados en la cuenta dueña del token. `from` apunta a
-- bsschoolcontrol.com, que es el dominio verificado hoy — no al de
-- Colombia Evaluadora. Cuando colombiaevaluadora.com esté verificado
-- con su SPF/DKIM, cambiar este valor es un UPDATE, sin desplegar.
-- ---------------------------------------------------------------
INSERT INTO provider_config
    (channel, provider_key, impl, enabled, priority, weight, policy, settings)
VALUES
    ('EMAIL', 'smtp-zeptomail', 'SMTP', TRUE, 2, 1, 'PRIORITY',
        jsonb_build_object(
            'host', 'smtp.zeptomail.com',
            'port', 587,
            'starttls', true,
            'username_env', 'SMTP_ZEPTOMAIL_USER',
            'password_env', 'SMTP_ZEPTOMAIL_PASS',
            'from', 'noreply@bsschoolcontrol.com'
        ))
ON CONFLICT (channel, provider_key) DO NOTHING;
