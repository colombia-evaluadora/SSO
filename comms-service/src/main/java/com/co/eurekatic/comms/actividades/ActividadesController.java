package com.co.eurekatic.comms.actividades;

import com.co.eurekatic.comms.actividades.ActividadesDtos.CalificarIn;
import com.co.eurekatic.comms.actividades.ActividadesDtos.Comunicado;
import com.co.eurekatic.comms.actividades.ActividadesDtos.ComunicadoIn;
import com.co.eurekatic.comms.actividades.ActividadesDtos.Eleccion;
import com.co.eurekatic.comms.actividades.ActividadesDtos.EleccionIn;
import com.co.eurekatic.comms.actividades.ActividadesDtos.Encuesta;
import com.co.eurekatic.comms.actividades.ActividadesDtos.EncuestaIn;
import com.co.eurekatic.comms.actividades.ActividadesDtos.EntregaEvaluacion;
import com.co.eurekatic.comms.actividades.ActividadesDtos.Evaluacion;
import com.co.eurekatic.comms.actividades.ActividadesDtos.EvaluacionIn;
import com.co.eurekatic.comms.actividades.ActividadesDtos.OpcionesVotantes;
import com.co.eurekatic.comms.actividades.ActividadesDtos.RespuestasIn;
import com.co.eurekatic.comms.actividades.ActividadesDtos.Votante;
import com.co.eurekatic.comms.actividades.ActividadesDtos.VotantesIn;
import com.co.eurekatic.comms.actividades.ActividadesDtos.VotoIn;
import com.co.eurekatic.comms.chat.ChatDtos.Conversacion;
import com.co.eurekatic.comms.chat.ChatDtos.Filas;
import com.co.eurekatic.comms.security.Usuario;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * REST de comunicados, encuestas, elecciones y evaluaciones: mismas rutas,
 * cuerpos y sobre {@code {rows}} que los mocks del front
 * ({@code src/mocks/handlers/comunicaciones-{comunicados,encuestas,elecciones,evaluaciones}.ts}).
 * Extension al mock: ENCUESTA y EVALUACION aceptan {@code PARTICIPANTES}.
 */
@RestController
@RequestMapping("/comunicaciones")
public class ActividadesController {

    private final ComunicadoService comunicados;
    private final EncuestaService encuestas;
    private final EleccionService elecciones;
    private final EvaluacionService evaluaciones;

    public ActividadesController(ComunicadoService comunicados, EncuestaService encuestas, EleccionService elecciones,
                                 EvaluacionService evaluaciones) {
        this.comunicados = comunicados;
        this.encuestas = encuestas;
        this.elecciones = elecciones;
        this.evaluaciones = evaluaciones;
    }

    // ── comunicados ────────────────────────────────────────────────────────

    @GetMapping("/conversaciones/{id}/comunicado")
    public Filas<Comunicado> comunicado(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(comunicados.ver(Usuario.de(r), id));
    }

    @PostMapping("/comunicados")
    public Filas<Conversacion> crearComunicado(HttpServletRequest r, @RequestBody ComunicadoIn in) {
        return Filas.de(comunicados.crear(Usuario.de(r), in));
    }

    // ── encuestas ──────────────────────────────────────────────────────────

    @GetMapping("/conversaciones/{id}/encuesta")
    public Filas<Encuesta> encuesta(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(encuestas.ver(Usuario.de(r), id));
    }

    @PostMapping("/conversaciones/{id}/encuesta/respuestas")
    public Filas<Encuesta> responder(HttpServletRequest r, @PathVariable long id, @RequestBody RespuestasIn in) {
        return Filas.de(encuestas.responder(Usuario.de(r), id, in.respuestas()));
    }

    @PostMapping("/encuestas")
    public Filas<Conversacion> crearEncuesta(HttpServletRequest r, @RequestBody EncuestaIn in) {
        return Filas.de(encuestas.crear(Usuario.de(r), in));
    }

    // ── elecciones ─────────────────────────────────────────────────────────

    @GetMapping("/votantes/opciones")
    public Filas<OpcionesVotantes> opcionesVotantes(HttpServletRequest r) {
        return Filas.de(elecciones.opcionesVotantes(Usuario.de(r)));
    }

    @PostMapping("/votantes/query")
    public Filas<Votante> votantes(HttpServletRequest r, @RequestBody VotantesIn in) {
        return new Filas<>(elecciones.votantes(Usuario.de(r), in.grupo(), in.valor()));
    }

    @GetMapping("/conversaciones/{id}/eleccion")
    public Filas<Eleccion> eleccion(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(elecciones.ver(Usuario.de(r), id));
    }

    @PostMapping("/conversaciones/{id}/eleccion/votar")
    public Filas<Eleccion> votar(HttpServletRequest r, @PathVariable long id, @RequestBody VotoIn in) {
        return Filas.de(elecciones.votar(Usuario.de(r), id, in.candidato()));
    }

    @PatchMapping("/conversaciones/{id}/eleccion/cerrar")
    public Filas<Conversacion> cerrar(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(elecciones.cerrar(Usuario.de(r), id));
    }

    @PostMapping("/elecciones")
    public Filas<Conversacion> crearEleccion(HttpServletRequest r, @RequestBody EleccionIn in) {
        return Filas.de(elecciones.crear(Usuario.de(r), in));
    }

    // ── evaluaciones ───────────────────────────────────────────────────────

    @GetMapping("/conversaciones/{id}/evaluacion")
    public Filas<Evaluacion> evaluacion(HttpServletRequest r, @PathVariable long id) {
        return Filas.de(evaluaciones.ver(Usuario.de(r), id));
    }

    @GetMapping("/conversaciones/{id}/evaluacion/entregas")
    public Filas<EntregaEvaluacion> entregas(HttpServletRequest r, @PathVariable long id) {
        return new Filas<>(evaluaciones.entregasDelCanal(Usuario.de(r), id));
    }

    @PostMapping("/conversaciones/{id}/evaluacion/entregas")
    public Filas<Evaluacion> entregar(HttpServletRequest r, @PathVariable long id, @RequestBody RespuestasIn in) {
        return Filas.de(evaluaciones.entregar(Usuario.de(r), id, in.respuestas()));
    }

    @PatchMapping("/evaluaciones/entregas/{id}")
    public Filas<EntregaEvaluacion> calificar(HttpServletRequest r, @PathVariable long id, @RequestBody CalificarIn in) {
        return Filas.de(evaluaciones.calificar(Usuario.de(r), id, in.calificaciones()));
    }

    @PostMapping("/evaluaciones")
    public Filas<Conversacion> crearEvaluacion(HttpServletRequest r, @RequestBody EvaluacionIn in) {
        return Filas.de(evaluaciones.crear(Usuario.de(r), in));
    }
}
