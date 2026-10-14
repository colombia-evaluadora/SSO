package com.co.eurekatic.aicontrol.agente.persistencia.identidad;

import java.util.Optional;

/** Quien es, en el esquema academico, la persona que usa el agente. */
public interface IdentidadAcademica {

    /** pk_tfuncionario del usuario de public.users; vacio si no es funcionario. */
    Optional<Long> funcionario(long userId);
}
