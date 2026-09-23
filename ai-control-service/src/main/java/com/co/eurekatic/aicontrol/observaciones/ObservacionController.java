package com.co.eurekatic.aicontrol.observaciones;

import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * Resumenes de observaciones de preescolar redactados por el modelo.
 * Por el gateway: {@code POST /api/ai/observaciones/...}.
 *
 * <p>Los nombres del cuerpo son los mismos de los endpoints de
 * query-service ({@code FK_TMATRICULA}, ...) para que el front no cambie de
 * convencion al pasar de "generar" a "generar con IA".
 */
@RestController
@RequestMapping("/ai/observaciones")
public class ObservacionController {

    private final ResumenObservacionService service;

    public ObservacionController(ResumenObservacionService service) {
        this.service = service;
    }

    public record PeriodoRequest(
            @JsonProperty("FK_TMATRICULA") @NotNull @Positive Long fkTmatricula,
            @JsonProperty("FK_TPERIODO_EVALUACION") @NotNull @Positive Long fkTperiodoEvaluacion,
            @JsonProperty("SOBRESCRIBIR") Boolean sobrescribir) {}

    public record AnioRequest(
            @JsonProperty("FK_TMATRICULA") @NotNull @Positive Long fkTmatricula,
            @JsonProperty("SOBRESCRIBIR") Boolean sobrescribir) {}

    /** Resumen de un periodo de evaluacion, a partir de las observaciones por actividad. */
    @PostMapping("/periodo")
    public ResumenResponse periodo(@Valid @RequestBody PeriodoRequest req, Authentication auth) {
        return service.generarYGuardar(TipoResumen.PERIODO,
                Map.of("FK_TMATRICULA", req.fkTmatricula(),
                        "FK_TPERIODO_EVALUACION", req.fkTperiodoEvaluacion()),
                Boolean.TRUE.equals(req.sobrescribir()), token(auth));
    }

    /** Consolidado del ano, a partir de los resumenes de periodo guardados. */
    @PostMapping("/anio")
    public ResumenResponse anio(@Valid @RequestBody AnioRequest req, Authentication auth) {
        return service.generarYGuardar(TipoResumen.ANIO,
                Map.of("FK_TMATRICULA", req.fkTmatricula()),
                Boolean.TRUE.equals(req.sobrescribir()), token(auth));
    }

    /** El filtro JWT deja el token crudo como credentials, para reenviarlo. */
    private static String token(Authentication auth) {
        return (String) auth.getCredentials();
    }
}
