package com.co.eurekatic.aicontrol.agente.web;

import com.co.eurekatic.aicontrol.agente.ui.sugerencias.SugerenciasService;
import com.co.eurekatic.aicontrol.agente.web.dto.SugerenciasDto;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * Sugerencias de mensajes para la pantalla abierta, bajo {@code /api/ai/agente/sugerencias}. Solo ofrece lo
 * que el usuario puede hacer con el asistente segun sus menus y roles.
 */
@RestController
@RequestMapping("/ai/agente")
public class SugerenciasController {

    private static final int MAX_RUTA = 1000;

    private final SugerenciasService sugerencias;

    public SugerenciasController(SugerenciasService sugerencias) {
        this.sugerencias = sugerencias;
    }

    @GetMapping("/sugerencias")
    public SugerenciasDto sugerencias(@RequestParam(name = "ruta", defaultValue = "") String ruta,
                                      Authentication autenticacion) {
        String acotada = ruta.length() > MAX_RUTA ? ruta.substring(0, MAX_RUTA) : ruta;
        return SugerenciasDto.de(sugerencias.para(UsuarioActual.de(autenticacion), acotada));
    }
}
