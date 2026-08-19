package com.co.eurekatic.auth.web.dto;

import com.co.eurekatic.common.security.PasswordPolicy;
import jakarta.validation.constraints.*;

import java.time.LocalDate;

public record RegisterUsuarioRequest(
    @NotBlank @Email @Size(max = 200) String email,
    @NotBlank @Size(max = 200) String fullName,
    @NotBlank @Size(min = PasswordPolicy.MIN_LENGTH, max = PasswordPolicy.MAX_LENGTH) String password,
    @NotBlank @Size(max = 30) String identificacion,
    @NotBlank @Size(max = 40) String primerNombre,
    @NotBlank @Size(max = 40) String primerApellido,
    // fechaNacimiento: sin @NotNull a propósito -- es uno de los dos
    // campos que el negocio pidió dejar opcional (columna nullable de
    // verdad en TUSUARIO, fn_usu_crear no la exige a nivel de fila).
    @Past LocalDate fechaNacimiento,
    // fkTlvTipoDocumento: @NotNull vuelto a agregar -- es uno de los 4
    // mínimos fijos (tipo/número de documento, nombre, apellido), nunca
    // debió quedar opcional; se había perdido junto con el @NotNull de
    // fkTlvGenero al relajar fechaNacimiento/fkTlvGenero.
    @NotNull @Positive Long fkTlvTipoDocumento,
    // fkTlvGenero: @NotNull restaurado -- el negocio volvió a pedir que
    // género sea obligatorio al crear (a diferencia de fechaNacimiento,
    // que sí se queda opcional). fn_usu_crear (SQL) nunca dejó de
    // exigirlo tampoco, así que esto solo estaba desalineado acá.
    @NotNull @Positive Long fkTlvGenero,
    @Size(max = 40) String segundoNombre,
    @Size(max = 40) String segundoApellido,
    @Size(max = 30) String telefono,
    @Email @Size(max = 120) String correoElectronico,
    @Positive Long fkTarchivoFoto,
    @Size(max = 2) String visado
) {}
