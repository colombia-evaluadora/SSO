package com.co.eurekatic.aicontrol.agente.catalogo.dominio;

/**
 * Valor que el agente pone desde la sesion en un parametro que el modelo no mando ({@code de_sesion} en el
 * catalogo). Es para fk que apuntan a la propia persona y que ninguna lectura le da antes de tiempo.
 */
public enum ValorDeSesion {

    /** pk_tfuncionario de la persona que pide. */
    FUNCIONARIO
}
