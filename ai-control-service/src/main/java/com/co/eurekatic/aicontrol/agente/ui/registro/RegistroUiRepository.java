package com.co.eurekatic.aicontrol.agente.ui.registro;

import java.util.List;

/** Puerto: pantallas y formularios registrados en el schema {@code ai}. */
public interface RegistroUiRepository {

    List<Pantalla> pantallas();

    List<FormularioRegistrado> formularios();
}
